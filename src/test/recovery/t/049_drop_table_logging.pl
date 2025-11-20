# Copyright (c) 2025, PostgreSQL Global Development Group

# Test DROP TABLE logging functionality
# This test verifies that DROP TABLE operations are logged with correct LSN values

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Initialize node with logging to stderr (not logging collector)
my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init;
$node->append_conf('postgresql.conf', qq{
log_min_messages = log
logging_collector = off
log_destination = 'stderr'
log_drop_lsn = on
});
$node->start;

# Helper function to count DROP TABLE logs
sub count_drop_logs
{
	my ($pattern) = @_;
	my $log = $node->log_content();
	my @matches = $log =~ /$pattern/g;
	return scalar @matches;
}

# Helper function to get recent log entries matching pattern
sub get_recent_logs
{
	my ($pattern, $count) = @_;
	my $log = $node->log_content();
	my @lines = split /\n/, $log;
	my @drop_lines = grep { /DROP TABLE:/ && /$pattern/ } @lines;
	return @drop_lines if $count == 0 || !defined($count);
	return @drop_lines[-$count..-1] if @drop_lines >= $count;
	return @drop_lines;
}

# Helper function to extract LSN from log line
sub extract_lsn
{
	my ($line, $lsn_type) = @_;
	if ($lsn_type eq 'drop')
	{
		if ($line =~ /drop LSN: ([0-9A-F]+\/[0-9A-F]+)/)
		{
			return $1;
		}
	}
	elsif ($lsn_type eq 'commit')
	{
		if ($line =~ /commit LSN: ([0-9A-F]+\/[0-9A-F]+)/)
		{
			return $1;
		}
	}
	return undef;
}

# Helper function to compare LSNs
sub lsn_less_than
{
	my ($lsn1, $lsn2) = @_;
	my ($seg1, $off1) = split /\//, $lsn1;
	my ($seg2, $off2) = split /\//, $lsn2;
	return (hex($seg1) < hex($seg2)) ||
	       (hex($seg1) == hex($seg2) && hex($off1) < hex($off2));
}

# Test 1: Simple DROP TABLE (autocommit)
$node->safe_psql('postgres', qq{
    CREATE TABLE test_simple (id int);
    INSERT INTO test_simple VALUES (1);
    DROP TABLE test_simple;
});

my $log = $node->log_content();
like($log, qr/DROP TABLE: relation "public\.test_simple"/,
     'Test 1: Simple DROP TABLE logged');
unlike($log, qr/DROP TABLE: relation "public\.test_simple".*commit LSN/s,
       'Test 1: Autocommit DROP has no commit LSN');

# Test 2: DROP TABLE inside transaction
$node->safe_psql('postgres', qq{
    BEGIN;
    CREATE TABLE test_in_xact (id int);
    INSERT INTO test_in_xact VALUES (1);
    DROP TABLE test_in_xact;
    COMMIT;
});

$log = $node->log_content();
like($log, qr/DROP TABLE: relation "public\.test_in_xact".*drop LSN:.*commit LSN:/s,
     'Test 2: DROP TABLE in transaction logged with commit LSN');

# Verify drop_lsn < commit_lsn
my @recent = get_recent_logs(qr/test_in_xact/, 1);
if (@recent)
{
	my $drop_lsn = extract_lsn($recent[0], 'drop');
	my $commit_lsn = extract_lsn($recent[0], 'commit');
	ok(defined($drop_lsn) && defined($commit_lsn),
	   'Test 2: Both LSNs extracted');
	ok(lsn_less_than($drop_lsn, $commit_lsn),
	   'Test 2: drop LSN < commit LSN');
}

# Test 3: DROP TABLE with ROLLBACK
$node->safe_psql('postgres', qq{
    CREATE TABLE test_rollback (id int);
    INSERT INTO test_rollback VALUES (1);
    BEGIN;
    DROP TABLE test_rollback;
    ROLLBACK;
    SELECT * FROM test_rollback;
    DROP TABLE test_rollback;
});

my $count = count_drop_logs(qr/DROP TABLE: relation "public\.test_rollback"/);
is($count, 1, 'Test 3: Only final DROP logged (after ROLLBACK)');

# Test 4: DROP SCHEMA CASCADE
$node->safe_psql('postgres', qq{
    CREATE SCHEMA test_schema;
    CREATE TABLE test_schema.table1 (id int);
    CREATE TABLE test_schema.table2 (name text);
    INSERT INTO test_schema.table1 VALUES (1);
    INSERT INTO test_schema.table2 VALUES ('test');
    BEGIN;
    DROP SCHEMA test_schema CASCADE;
    COMMIT;
});

my $table1_count = count_drop_logs(qr/DROP TABLE: relation "test_schema\.table1"/);
my $table2_count = count_drop_logs(qr/DROP TABLE: relation "test_schema\.table2"/);
is($table1_count, 1, 'Test 4: table1 logged');
is($table2_count, 1, 'Test 4: table2 logged');

# Test 5: DROP TABLE with FK CASCADE
$node->safe_psql('postgres', qq{
    CREATE TABLE test_parent (id int PRIMARY KEY);
    CREATE TABLE test_child (id int, parent_id int REFERENCES test_parent(id));
    INSERT INTO test_parent VALUES (1);
    INSERT INTO test_child VALUES (1, 1);
    BEGIN;
    DROP TABLE test_parent CASCADE;
    COMMIT;
});

my $parent_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_parent"/);
is($parent_count, 1, 'Test 5: Only parent logged (FK CASCADE drops constraints, not tables)');

# Test 6: Multiple DROP TABLE
$node->safe_psql('postgres', qq{
    CREATE TABLE test_multi1 (id int);
    CREATE TABLE test_multi2 (id int);
    CREATE TABLE test_multi3 (id int);
    BEGIN;
    DROP TABLE test_multi1, test_multi2, test_multi3;
    COMMIT;
});

my $multi1 = count_drop_logs(qr/DROP TABLE: relation "public\.test_multi1"/);
my $multi2 = count_drop_logs(qr/DROP TABLE: relation "public\.test_multi2"/);
my $multi3 = count_drop_logs(qr/DROP TABLE: relation "public\.test_multi3"/);
is($multi1 + $multi2 + $multi3, 3, 'Test 6: All three tables logged');

# Test 7: DROP PARTITIONED TABLE
$node->safe_psql('postgres', qq{
    CREATE TABLE test_partitioned (id int, created_at date) PARTITION BY RANGE (created_at);
    CREATE TABLE test_part_2024 PARTITION OF test_partitioned
        FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
    CREATE TABLE test_part_2025 PARTITION OF test_partitioned
        FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
    BEGIN;
    DROP TABLE test_partitioned CASCADE;
    COMMIT;
});

my $part_parent = count_drop_logs(qr/DROP TABLE: relation "public\.test_partitioned"/);
my $part_2024 = count_drop_logs(qr/DROP TABLE: relation "public\.test_part_2024"/);
my $part_2025 = count_drop_logs(qr/DROP TABLE: relation "public\.test_part_2025"/);
is($part_parent + $part_2024 + $part_2025, 3,
   'Test 7: Partitioned table and all partitions logged');

# Test 8: Mixed operations in one transaction
$node->safe_psql('postgres', qq{
    CREATE SCHEMA mixed_schema;
    BEGIN;
    CREATE TABLE mixed_schema.table1 (id int);
    INSERT INTO mixed_schema.table1 VALUES (1);
    CREATE TABLE mixed_schema.table2 (id int);
    DROP TABLE mixed_schema.table2;
    CREATE TABLE outside_table (id int);
    INSERT INTO outside_table VALUES (1);
    DROP SCHEMA mixed_schema CASCADE;
    DROP TABLE outside_table;
    COMMIT;
});

my $mixed_count = count_drop_logs(qr/DROP TABLE: relation "mixed_schema\.table[12]"/);
my $outside_count = count_drop_logs(qr/DROP TABLE: relation "public\.outside_table"/);
is($mixed_count + $outside_count, 3, 'Test 8: All three tables logged in mixed transaction');

# Test 9: DROP temporary table
$node->safe_psql('postgres', qq{
    CREATE TEMP TABLE test_temp (id int);
    INSERT INTO test_temp VALUES (1);
    BEGIN;
    DROP TABLE test_temp;
    COMMIT;
});

my $temp_count = count_drop_logs(qr/DROP TABLE: relation "pg_temp_\d+\.test_temp"/);
is($temp_count, 1, 'Test 10: Temp table DROP logged');

# Test 10: DROP VIEW (should not be logged)
$node->safe_psql('postgres', qq{
    CREATE TABLE test_view_base (id int);
    CREATE VIEW test_view AS SELECT * FROM test_view_base;
    DROP VIEW test_view;
    DROP TABLE test_view_base;
});

my $view_count = count_drop_logs(qr/DROP TABLE: relation test_view[^_]/);
is($view_count, 0, 'Test 11: VIEW drop not logged');
my $view_base_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_view_base"/);
is($view_base_count, 1, 'Test 11: Base table drop logged');

# Test 11: DROP INDEX (should not be logged)
$node->safe_psql('postgres', qq{
    CREATE TABLE test_index_table (id int);
    CREATE INDEX test_idx ON test_index_table(id);
    DROP INDEX test_idx;
    DROP TABLE test_index_table;
});

my $index_count = count_drop_logs(qr/DROP TABLE: relation test_idx/);
is($index_count, 0, 'Test 12: INDEX drop not logged');
my $index_table_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_index_table"/);
is($index_table_count, 1, 'Test 12: Table drop logged');

# Test 12: Table inheritance hierarchy
$node->safe_psql('postgres', qq{
    CREATE TABLE parent_inherit (id int);
    CREATE TABLE child_inherit1 () INHERITS (parent_inherit);
    CREATE TABLE child_inherit2 () INHERITS (parent_inherit);
    INSERT INTO parent_inherit VALUES (1);
    INSERT INTO child_inherit1 VALUES (2);
    INSERT INTO child_inherit2 VALUES (3);
    BEGIN;
    DROP TABLE parent_inherit CASCADE;
    COMMIT;
});

my $inh_parent = count_drop_logs(qr/DROP TABLE: relation "public\.parent_inherit"/);
my $inh_child1 = count_drop_logs(qr/DROP TABLE: relation "public\.child_inherit1"/);
my $inh_child2 = count_drop_logs(qr/DROP TABLE: relation "public\.child_inherit2"/);
is($inh_parent + $inh_child1 + $inh_child2, 3,
   'Test 13: Inheritance hierarchy all logged');

# Test 13: Nested transaction with SAVEPOINT
$node->safe_psql('postgres', qq{
    CREATE TABLE test_savepoint1 (id int);
    CREATE TABLE test_savepoint2 (id int);
    CREATE TABLE test_savepoint3 (id int);
    BEGIN;
    DROP TABLE test_savepoint1;
    SAVEPOINT sp1;
    DROP TABLE test_savepoint2;
    ROLLBACK TO sp1;
    DROP TABLE test_savepoint3;
    COMMIT;
});

my $sp1_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_savepoint1"/);
my $sp2_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_savepoint2"/);
my $sp3_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_savepoint3"/);
is($sp1_count, 1, 'Test 14: savepoint1 logged');
is($sp2_count, 0, 'Test 14: savepoint2 NOT logged (rolled back)');
is($sp3_count, 1, 'Test 14: savepoint3 logged');

# Test 14: COMMIT AND CHAIN
$node->safe_psql('postgres', qq{
    CREATE TABLE chain_test1 (id int);
    CREATE TABLE chain_test2 (id int);
    CREATE TABLE chain_test3 (id int);
    CREATE TABLE chain_test4 (id int);
    BEGIN;
    DROP TABLE chain_test1;
    INSERT INTO chain_test2 VALUES (1);
    DROP TABLE chain_test2;
    COMMIT AND CHAIN;
    DROP TABLE chain_test3;
    COMMIT AND CHAIN;
    DROP TABLE chain_test4;
    COMMIT;
});

my @chain_logs = get_recent_logs(qr/DROP TABLE: relation "public\.chain_test[1-4]/, 0);
is(scalar @chain_logs, 4, 'Test 15: Four COMMIT AND CHAIN drops logged');

# Verify different commit LSNs
if (@chain_logs >= 4)
{
	my $commit_lsn1 = extract_lsn($chain_logs[0], 'commit');
	my $commit_lsn2 = extract_lsn($chain_logs[1], 'commit');
	my $commit_lsn3 = extract_lsn($chain_logs[2], 'commit');
	my $commit_lsn4 = extract_lsn($chain_logs[3], 'commit');

	# First two should have same commit LSN
	is($commit_lsn1, $commit_lsn2,
	   'Test 15: chain_test1 and chain_test2 have same commit LSN');

	# Others should be different
	isnt($commit_lsn2, $commit_lsn3,
	     'Test 15: chain_test3 has different commit LSN');
	isnt($commit_lsn3, $commit_lsn4,
	     'Test 15: chain_test4 has different commit LSN');
}

# Test 15: ROLLBACK AND CHAIN
$node->safe_psql('postgres', qq{
    CREATE TABLE rollback_chain1 (id int);
    CREATE TABLE rollback_chain2 (id int);
    CREATE TABLE rollback_chain3 (id int);
    BEGIN;
    DROP TABLE rollback_chain1;
    ROLLBACK AND CHAIN;
    DROP TABLE rollback_chain2;
    COMMIT AND CHAIN;
    DROP TABLE rollback_chain3;
    COMMIT;
});

my $rb_chain1 = count_drop_logs(qr/DROP TABLE: relation "public\.rollback_chain1"/);
my $rb_chain2 = count_drop_logs(qr/DROP TABLE: relation "public\.rollback_chain2"/);
my $rb_chain3 = count_drop_logs(qr/DROP TABLE: relation "public\.rollback_chain3"/);
is($rb_chain1, 0, 'Test 16: rollback_chain1 NOT logged (rolled back)');
is($rb_chain2, 1, 'Test 16: rollback_chain2 logged');
is($rb_chain3, 1, 'Test 16: rollback_chain3 logged');

# Test 16: COMMIT AND CHAIN with SAVEPOINTs
$node->safe_psql('postgres', qq{
    CREATE TABLE chain_sp1 (id int);
    CREATE TABLE chain_sp2 (id int);
    CREATE TABLE chain_sp3 (id int);
    CREATE TABLE chain_sp4 (id int);
    BEGIN;
    DROP TABLE chain_sp1;
    SAVEPOINT sp1;
    DROP TABLE chain_sp2;
    ROLLBACK TO sp1;
    DROP TABLE chain_sp3;
    COMMIT AND CHAIN;
    DROP TABLE chain_sp4;
    COMMIT;
});

my $csp1 = count_drop_logs(qr/DROP TABLE: relation "public\.chain_sp1"/);
my $csp2 = count_drop_logs(qr/DROP TABLE: relation "public\.chain_sp2"/);
my $csp3 = count_drop_logs(qr/DROP TABLE: relation "public\.chain_sp3"/);
my $csp4 = count_drop_logs(qr/DROP TABLE: relation "public\.chain_sp4"/);
is($csp1, 1, 'Test 17: chain_sp1 logged');
is($csp2, 0, 'Test 17: chain_sp2 NOT logged (rolled back)');
is($csp3, 1, 'Test 17: chain_sp3 logged');
is($csp4, 1, 'Test 17: chain_sp4 logged');

# Test 17: Multiple COMMIT AND CHAIN cycles
$node->safe_psql('postgres', qq{
    CREATE TABLE cycle1 (id int);
    CREATE TABLE cycle2 (id int);
    CREATE TABLE cycle3 (id int);
    CREATE TABLE cycle4 (id int);
    CREATE TABLE cycle5 (id int);
    BEGIN;
    DROP TABLE cycle1;
    COMMIT AND CHAIN;
    DROP TABLE cycle2;
    COMMIT AND CHAIN;
    DROP TABLE cycle3;
    COMMIT AND CHAIN;
    DROP TABLE cycle4;
    COMMIT AND CHAIN;
    DROP TABLE cycle5;
    COMMIT;
});

my @cycle_logs = get_recent_logs(qr/DROP TABLE: relation "public\.cycle\d"/, 0);
is(scalar @cycle_logs, 5, 'Test 18: Five cycle drops logged');

# Verify all have different commit LSNs
if (@cycle_logs >= 5)
{
	my @cycle_lsns = map { extract_lsn($_, 'commit') } @cycle_logs;
	my %unique_lsns = map { $_ => 1 } grep { defined } @cycle_lsns;
	is(scalar keys %unique_lsns, 5,
	   'Test 18: All five cycles have unique commit LSNs');
}

# Test: DROP DATABASE
$node->safe_psql('postgres', 'CREATE DATABASE test_drop_db;');
$node->safe_psql('postgres', 'DROP DATABASE test_drop_db;');

my $db_count = count_drop_logs(qr/DROP DATABASE: database "test_drop_db"/);
is($db_count, 1, 'DROP DATABASE logged');

done_testing();
