use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::RecursiveCopy;
use PostgreSQL::Test::Utils;
use Test::More;
use Data::Dumper;

my $node = PostgreSQL::Test::Cluster->new('main');

# Create a data directory with initdb
$node->init;

$node->append_conf(
    'postgresql.conf', 
    q{
        wal_level = 'replica'
        archive_mode = 'on'
        archive_library = 'wal_diff'
        wal_diff.wal_diff_directory = 'wal_diff'
        shared_preload_libraries = 'wal_diff'
    }
);

# Start the PostgreSQL server
$node->start;

# Setup
$node->safe_psql('postgres', 'CREATE EXTENSION wal_diff');

# Create table wich contain writer_state struct, because we
# need to pass it through processes
$node->safe_psql(
        'postgres', 
        "CREATE TABLE writer_state (
        id INTEGER PRIMARY KEY,
        src_fd INTEGER,
        dest_fd INTEGER,
        src_fd_pos bigint,

        src_path text,
        src_dir text,
        dest_path text,
        dest_dir text,
        fname text,

        wal_segment_size integer,
        sys_id bigint,
        page_addr bigint,
        tli integer,

        src_curr_offset bigint,
        dest_curr_offset bigint,

        last_read_rec bigint,
        last_read_rec_size bigint,

        last_written_rec bigint,
        last_written_rec_len bigint
        );"
);

# Insert initial values
$node->safe_psql(
    'postgres', 
    "INSERT INTO writer_state (id, src_fd_pos, dest_curr_offset, dest_dir) VALUES (1, 0, 0, '');"
);

# Create wal/wal diff file names
my $wal_file = $node->data_dir . '/pg_wal/000000010000000000000001';
my $wal_diff_file = $node->data_dir . '/wal_diff/000000010000000000000001';
ok(-f -e $wal_file, "Got a wal file");

my $read_record;
my $total_read_count = 0;
my $num_records = 10;

# Read record from wal segment and write it to wal_diff
# segment $num_records times
for (my $iter = 0; $iter < $num_records; $iter++) {
    eval {
        $read_record = $node->safe_psql(
            'postgres', 
            "SELECT read_xlog_rec('$wal_file');"
        );
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $node->stop('immediate');
        BAIL_OUT("Failed to execute 'read_xlog_rec' ");
    };

    my $binary_string = pack('H*', substr($read_record, 2));
    my @rec = unpack( 'H*', $binary_string );
    @rec = map { $_ } @rec;

    my @new_array;
    for (my $i = 0; $i < length(@rec[0]); $i+=2) {
        push @new_array, substr(@rec[0], $i, 2);
    }

    $total_read_count += scalar @new_array;

    eval {
        $node->safe_psql(
            'postgres', 
            "SELECT write_xlog_rec('$wal_diff_file', '$read_record');"
        );
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $node->stop('immediate');
        BAIL_OUT("Failed to execute 'write_xlog_rec' ");
    };
}

my $size = -s $wal_diff_file;
ok($size == $total_read_count, "Read bytes == write bytes");

# Read all read wal and all written wal_diff
my ($buffer1, $buffer2);
open(my $fh1, '<:raw', $wal_file) or die "Cannot open file '$wal_file': $!";
open(my $fh2, '<:raw', $wal_diff_file) or die "Cannot open file '$wal_diff_file': $!";
my $bytes_read1 = read($fh1, $buffer1, $total_read_count);
my $bytes_read2 = read($fh2, $buffer2, $total_read_count);
close($fh1);
close($fh2);

# Try to find positions, where wal differ wal_diff
my $is_equal = 1;
for (my $i = 0; $i < $total_read_count; $i++) {
    if (substr($buffer1, $i, 1) ne substr($buffer2, $i, 1)) {
        diag("NOT EQUAL IN POSITION:");
        diag($i);
        $is_equal = 0;
    }
}
ok($is_equal == 1, "Wal diff file is equal to wal file");

# Stop the server
$node->stop('immediate');
done_testing();