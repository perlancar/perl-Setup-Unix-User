#!perl

use 5.010;
use strict;
use warnings;

use FindBin '$Bin';
use lib $Bin, "$Bin/t";

use Test::More 0.96;
require "testlib.pl";

setup();

test_setup_unix_group(
    name       => "create",
    args       => {group=>"g1"},
    after_do   => {gid=>3},
    after_undo => {exists=>0},
);
test_setup_unix_group(
    name       => "create with min_new_gid & max_new_gid",
    args       => {group=>"g2", min_new_gid=>1000, max_new_gid=>1002},
    after_do   => {gid=>1001},
    after_undo => {exists=>0},
);
test_setup_unix_group(
    name       => "create failed due gids unavailable",
    args       => {group=>"g3", min_new_gid=>1000, max_new_gid=>1000},
    status     => 412,
);
test_setup_unix_group(
    name       => "create already created -> noop",
    args       => {group=>"u1", min_new_gid=>1001, max_new_gid=>1001},
    status     => 304,
);
goto DONE_TESTING;

DONE_TESTING:
teardown();
