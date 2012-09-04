#!perl

use 5.010;
use strict;
use warnings;
use FindBin '$Bin';

use File::chdir;
use File::Path qw(remove_tree);
use File::Copy::Recursive qw(rcopy);
use File::Temp qw(tempdir);
use Setup::Unix::Group;
use Test::More 0.96;
use Test::Perinci::Tx::Manager qw(test_tx_action);
use Unix::Passwd::File qw(get_group);

my $tmpdir = tempdir(CLEANUP=>1);
$CWD = $tmpdir;
my %ca = (etc_dir => "$tmpdir/etc");

test_tx_action(
    name        => "fixed: group already exists",
    tmpdir      => $tmpdir,
    f           => "Setup::Unix::Group::addgroup",
    args        => {etc_dir=>"$tmpdir/etc", group=>"u1"},
    reset_state => sub {
        remove_tree "etc";
        rcopy "$Bin/data/simple", "etc";
    },
    status      => 304,
);

test_tx_action(
    name        => "unfixable: group already exists with different gid",
    tmpdir      => $tmpdir,
    f           => "Setup::Unix::Group::addgroup",
    args        => {etc_dir=>"$tmpdir/etc", group=>"u1", gid=>1001},
    reset_state => sub {
        remove_tree "etc";
        rcopy "$Bin/data/simple", "etc";
    },
    status      => 412,
);

test_tx_action(
    name        => "add",
    tmpdir      => $tmpdir,
    f           => "Setup::Unix::Group::addgroup",
    args        => {%ca, group=>"foo"},
    reset_state => sub {
        remove_tree "etc";
        rcopy "$Bin/data/simple", "etc";
    },
    after_do    => sub {
        my $res = get_group(%ca, group=>"foo");
        is($res->[0], 200, "group exists");
        is($res->[2]{gid}, 1002, "gid");
    },
    after_undo  => sub {
        my $res = get_group(%ca, group=>"foo");
        is($res->[0], 404, "group doesn't exist");
    },
);

test_tx_action(
    name        => "gid argument, add non-unique gid is ok",
    tmpdir      => $tmpdir,
    f           => "Setup::Unix::Group::addgroup",
    args        => {etc_dir=>"$tmpdir/etc", group=>"foo", gid=>1001},
    reset_state => sub {
        remove_tree "etc";
        rcopy "$Bin/data/simple", "etc";
    },
    after_do    => sub {
        my $res = get_group(%ca, group=>"foo");
        is($res->[0], 200, "group exists");
        is($res->[2]{gid}, 1001, "gid");
    },
    after_undo  => sub {
        my $res = get_group(%ca, group=>"foo");
        is($res->[0], 404, "group doesn't exist");
    },
);

DONE_TESTING:
done_testing();
if (Test::More->builder->is_passing) {
    #note "all tests successful, deleting temp files";
    $CWD = "/";
} else {
    diag "there are failing tests, not deleting tempdir $tmpdir";
}
