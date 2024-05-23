/* contrib/wal_diff/wal_diff--1.0.sql */

CREATE FUNCTION read_xlog_rec(TEXT) RETURNS BYTEA
AS 'MODULE_PATHNAME', 'read_xlog_rec'
LANGUAGE C STRICT;

CREATE FUNCTION write_xlog_rec(TEXT, BYTEA) RETURNS VOID
AS 'MODULE_PATHNAME', 'write_xlog_rec'
LANGUAGE C STRICT;