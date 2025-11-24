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

# Track log file position for incremental reading
my $log_offset = 0;

# Cache for current test - stores log content read once per test
my $current_test_log_cache = undef;

# Reset to start a new test - clears cache and updates offset
sub start_new_test
{
	my ($test_name) = @_;
	note($test_name) if defined $test_name;

	$current_test_log_cache = undef;

	# Update offset to current position
	my $logfile = $node->logfile;
	$log_offset = -s $logfile;
}

# Get log content for current test (cached within test)
sub get_test_log_content
{
	return $current_test_log_cache if defined $current_test_log_cache;

	# Read new content since last test started
	my $logfile = $node->logfile;
	my $current_size = -s $logfile;

	# If offset is beyond file size, reset to 0
	$log_offset = 0 if $log_offset > $current_size;

	# Read only new content
	$current_test_log_cache = slurp_file($logfile, $log_offset);

	return $current_test_log_cache;
}

# Count matching log entries in current test
sub count_drop_logs
{
	my ($pattern) = @_;
	my $log = get_test_log_content();
	my @matches = $log =~ /$pattern/g;
	return scalar @matches;
}

# Get matching log lines in current test
sub get_log_lines
{
	my ($pattern) = @_;
	my $log = get_test_log_content();
	my @lines = split /\n/, $log;
	my @matching_lines = grep { /$pattern/ } @lines;
	return @matching_lines;
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
	elsif ($lsn_type eq 'single')
	{
		# For autocommit operations with single LSN
		if ($line =~ /LSN: ([0-9A-F]+\/[0-9A-F]+)/)
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
start_new_test('Test 1: Simple DROP TABLE in autocommit mode');

$node->safe_psql('postgres', qq{
    CREATE TABLE test_simple (id int);
    INSERT INTO test_simple VALUES (1);
    DROP TABLE test_simple;
});

my @log_lines = get_log_lines(qr/DROP TABLE: relation "public\.test_simple"/);
is(scalar @log_lines, 1, 'Test 1: Simple DROP TABLE logged');

# Autocommit should have single LSN, not separate drop and commit LSNs
like($log_lines[0], qr/LSN: [0-9A-F]+\/[0-9A-F]+/,
     'Test 1: LSN present in log');
unlike($log_lines[0], qr/commit LSN/,
       'Test 1: Autocommit DROP has no separate commit LSN');

# Test 2: DROP TABLE inside transaction
start_new_test('Test 2: DROP TABLE inside explicit transaction');

$node->safe_psql('postgres', qq{
    BEGIN;
    CREATE TABLE test_in_xact (id int);
    INSERT INTO test_in_xact VALUES (1);
    DROP TABLE test_in_xact;
    COMMIT;
});

@log_lines = get_log_lines(qr/DROP TABLE: relation "public\.test_in_xact"/);
is(scalar @log_lines, 1, 'Test 2: DROP TABLE in transaction logged');

# Should have both drop LSN and commit LSN
like($log_lines[0], qr/drop LSN:.*commit LSN:/s,
     'Test 2: Both drop and commit LSNs logged');

# Verify drop_lsn < commit_lsn
my $drop_lsn = extract_lsn($log_lines[0], 'drop');
my $commit_lsn = extract_lsn($log_lines[0], 'commit');
ok(defined($drop_lsn) && defined($commit_lsn),
   'Test 2: Both LSNs extracted successfully');
ok(lsn_less_than($drop_lsn, $commit_lsn),
   'Test 2: drop LSN < commit LSN');

# Test 3: DROP TABLE with ROLLBACK
start_new_test('Test 3: DROP TABLE with ROLLBACK - should not be logged');

$node->safe_psql('postgres', qq{
    CREATE TABLE test_rollback (id int);
    INSERT INTO test_rollback VALUES (1);
    BEGIN;
    DROP TABLE test_rollback;
    ROLLBACK;
});

my $rollback_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_rollback"/);
is($rollback_count, 0, 'Test 3: Rolled back DROP not logged');

# Now actually drop the table
start_new_test();
$node->safe_psql('postgres', qq{
    SELECT * FROM test_rollback;
    DROP TABLE test_rollback;
});

$rollback_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_rollback"/);
is($rollback_count, 1, 'Test 3: Committed DROP logged');

# Test 4: DROP SCHEMA CASCADE
start_new_test('Test 4: DROP SCHEMA CASCADE - all tables logged');

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
start_new_test('Test 5: DROP TABLE CASCADE with foreign keys');

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

# Test 6: Multiple DROP TABLE in single statement
start_new_test('Test 6: Multiple tables in single DROP statement');

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
is($multi1, 1, 'Test 6: First table logged');
is($multi2, 1, 'Test 6: Second table logged');
is($multi3, 1, 'Test 6: Third table logged');

# Test 7: DROP PARTITIONED TABLE
start_new_test('Test 7: Partitioned table and partitions');

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
is($part_parent, 1, 'Test 7: Partitioned table logged');
is($part_2024, 1, 'Test 7: First partition logged');
is($part_2025, 1, 'Test 7: Second partition logged');

# Test 8: Mixed operations in one transaction
start_new_test('Test 8: Mixed CREATE and DROP operations in transaction');

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

my $mixed1_count = count_drop_logs(qr/DROP TABLE: relation "mixed_schema\.table1"/);
my $mixed2_count = count_drop_logs(qr/DROP TABLE: relation "mixed_schema\.table2"/);
my $outside_count = count_drop_logs(qr/DROP TABLE: relation "public\.outside_table"/);
is($mixed1_count, 1, 'Test 8: Schema table1 logged');
is($mixed2_count, 1, 'Test 8: Schema table2 logged');
is($outside_count, 1, 'Test 8: Outside table logged');

# Test 9: DROP temporary table
start_new_test('Test 9: Temporary table');

$node->safe_psql('postgres', qq{
    CREATE TEMP TABLE test_temp (id int);
    INSERT INTO test_temp VALUES (1);
    BEGIN;
    DROP TABLE test_temp;
    COMMIT;
});

my $temp_count = count_drop_logs(qr/DROP TABLE: relation "pg_temp_\d+\.test_temp"/);
is($temp_count, 1, 'Test 9: Temp table DROP logged');

# Test 10: DROP VIEW (should not be logged)
start_new_test('Test 10: Views should not be logged');

$node->safe_psql('postgres', qq{
    CREATE TABLE test_view_base (id int);
    CREATE VIEW test_view AS SELECT * FROM test_view_base;
    DROP VIEW test_view;
    DROP TABLE test_view_base;
});

my $view_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_view"[^\w]/);
is($view_count, 0, 'Test 10: VIEW drop not logged');
my $view_base_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_view_base"/);
is($view_base_count, 1, 'Test 10: Base table drop logged');

# Test 11: DROP INDEX (should not be logged)
start_new_test('Test 11: Indexes should not be logged');

$node->safe_psql('postgres', qq{
    CREATE TABLE test_index_table (id int);
    CREATE INDEX test_idx ON test_index_table(id);
    DROP INDEX test_idx;
    DROP TABLE test_index_table;
});

my $index_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_idx"/);
is($index_count, 0, 'Test 11: INDEX drop not logged');
my $index_table_count = count_drop_logs(qr/DROP TABLE: relation "public\.test_index_table"/);
is($index_table_count, 1, 'Test 11: Table drop logged');

# Test 12: Table inheritance hierarchy
start_new_test('Test 12: Inheritance hierarchy');

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
is($inh_parent, 1, 'Test 12: Parent table logged');
is($inh_child1, 1, 'Test 12: First child logged');
is($inh_child2, 1, 'Test 12: Second child logged');

# Test 13: Nested transaction with SAVEPOINT
start_new_test('Test 13: SAVEPOINT and ROLLBACK TO');

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
is($sp1_count, 1, 'Test 13: savepoint1 logged');
is($sp2_count, 0, 'Test 13: savepoint2 NOT logged (rolled back)');
is($sp3_count, 1, 'Test 13: savepoint3 logged');

# Test 14: COMMIT AND CHAIN
start_new_test('Test 14: COMMIT AND CHAIN with multiple cycles');

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

my @chain_logs = get_log_lines(qr/DROP TABLE: relation "public\.chain_test[1-4]/);
is(scalar @chain_logs, 4, 'Test 14: Four COMMIT AND CHAIN drops logged');

# Verify commit LSNs
if (@chain_logs >= 4)
{
	my @commit_lsns = map { extract_lsn($_, 'commit') } @chain_logs;

	# First two should have same commit LSN (same transaction)
	is($commit_lsns[0], $commit_lsns[1],
	   'Test 14: chain_test1 and chain_test2 have same commit LSN');

	# Others should be different (different transactions)
	isnt($commit_lsns[1], $commit_lsns[2],
	     'Test 14: chain_test3 has different commit LSN');
	isnt($commit_lsns[2], $commit_lsns[3],
	     'Test 14: chain_test4 has different commit LSN');
}

# Test 15: ROLLBACK AND CHAIN
start_new_test('Test 15: ROLLBACK AND CHAIN');

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
is($rb_chain1, 0, 'Test 15: rollback_chain1 NOT logged (rolled back)');
is($rb_chain2, 1, 'Test 15: rollback_chain2 logged');
is($rb_chain3, 1, 'Test 15: rollback_chain3 logged');

# Test 16: COMMIT AND CHAIN with SAVEPOINTs
start_new_test('Test 16: COMMIT AND CHAIN combined with SAVEPOINTs');

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
is($csp1, 1, 'Test 16: chain_sp1 logged');
is($csp2, 0, 'Test 16: chain_sp2 NOT logged (rolled back)');
is($csp3, 1, 'Test 16: chain_sp3 logged');
is($csp4, 1, 'Test 16: chain_sp4 logged');

# Test 17: Multiple COMMIT AND CHAIN cycles
start_new_test('Test 17: Five consecutive COMMIT AND CHAIN operations');

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

my @cycle_logs = get_log_lines(qr/DROP TABLE: relation "public\.cycle\d"/);
is(scalar @cycle_logs, 5, 'Test 17: Five cycle drops logged');

# Verify all have different commit LSNs (each is separate transaction)
if (@cycle_logs >= 5)
{
	my @cycle_lsns = map { extract_lsn($_, 'commit') } @cycle_logs;
	my %unique_lsns = map { $_ => 1 } grep { defined } @cycle_lsns;
	is(scalar keys %unique_lsns, 5,
	   'Test 17: All five cycles have unique commit LSNs');
}

# Test 18: DROP DATABASE
start_new_test('Test 18: DROP DATABASE');

$node->safe_psql('postgres', 'CREATE DATABASE test_drop_db;');
$node->safe_psql('postgres', 'DROP DATABASE test_drop_db;');

my $db_count = count_drop_logs(qr/DROP DATABASE: database "test_drop_db"/);
is($db_count, 1, 'Test 18: DROP DATABASE logged');

# Verify it has single LSN (cannot be in transaction)
@log_lines = get_log_lines(qr/DROP DATABASE: database "test_drop_db"/);
if (@log_lines)
{
	unlike($log_lines[0], qr/commit LSN/,
	       'Test 18: DROP DATABASE has no commit LSN (not in transaction)');
	like($log_lines[0], qr/LSN: [0-9A-F]+\/[0-9A-F]+/,
	     'Test 18: DROP DATABASE has single LSN');
}

# Test 19: PL/pgSQL function with EXCEPTION block (subtransaction)
start_new_test('Test 19: DROP in PL/pgSQL with EXCEPTION handler');

$node->safe_psql('postgres', qq{
    CREATE TABLE plpgsql_test (id int);

    CREATE FUNCTION test_drop_with_exception() RETURNS void AS \$\$
    BEGIN
        DROP TABLE plpgsql_test;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'Exception caught';
    END;
    \$\$ LANGUAGE plpgsql;

    -- Call in autocommit - but creates subtransaction internally
    SELECT test_drop_with_exception();
});

my $plpgsql_count = count_drop_logs(qr/DROP TABLE: relation "public\.plpgsql_test"/);
is($plpgsql_count, 1, 'Test 19: DROP in PL/pgSQL EXCEPTION block logged');

# Should have commit LSN even though called in autocommit
# because PL/pgSQL EXCEPTION creates subtransaction
@log_lines = get_log_lines(qr/DROP TABLE: relation "public\.plpgsql_test"/);
if (@log_lines)
{
	like($log_lines[0], qr/commit LSN/,
	     'Test 19: PL/pgSQL subtransaction has commit LSN');
}

done_testing();
