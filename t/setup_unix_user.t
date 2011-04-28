#!perl

use 5.010;
use strict;
use warnings;

use FindBin '$Bin';
use lib $Bin, "$Bin/t";

use Test::More 0.96;
require "testlib.pl";

use vars qw($tmp_dir $undo_data $redo_data);

setup();

test_setup_unix_user(
    name       => "create (dry run)",
    args       => {name=>"u3", -dry_run=>1},
    status     => 200,
    exists     => 0,
);
test_setup_unix_user(
    name       => "create (with create_home_dir=0)",
    args       => {name=>"u3", create_home_dir=>0},
    status     => 200,
    posttest   => sub {
        my $res = shift;
        is($res->[2]{uid}, 3, "uid");
        is($res->[2]{gid}, 3, "gid");
    },
);
my %args = (
    name=>"u4", min_new_uid=>1000, new_password=>"123", new_gecos=>"user 4",
    new_home_dir=>"$tmp_dir/home", new_home_dir_mode=>0750,
    new_shell=>"/bin/shell", member_of=>["bin", "test"],
    skel_dir=>"$tmp_dir/skel",
);
test_setup_unix_user(
    name       => "create (with undo, min_new_uid, new_password, new_gecos, ".
        "new_home_dir, new_home_dir_mode, new_shell, member_of)",
    args       => {%args,
                   -undo_action=>"do"},
    status     => 200,
    is_file    => 1,
    posttest   => sub {
        my ($res, $name, $pu) = @_;
        $undo_data = $res->[3]{undo_data};
        is($res->[2]{uid}, 1002, "uid");
        is($res->[2]{gid}, 1003, "gid");
        my @u = $pu->user($name);
        # XXX test new_password
        is($u[3], "user 4", "new_gecos");
        is($u[4], "$tmp_dir/home", "new_home_dir");
        is($u[5], "/bin/shell", "new_shell");
        ok((-d "$tmp_dir/home"), "home dir created");
        ok((-f "$tmp_dir/home/.dir1/.file1"), "skel file/dir created 1a");
        is(read_file("$tmp_dir/home/.dir1/.file1", err_mode=>'quiet'), "file 1",
           "skel file/dir created 1b");
        ok((-f "$tmp_dir/home/.file2"), "skel file/dir created 2a");
        is(read_file("$tmp_dir/home/.file2", err_mode=>'quiet'), "file 2",
           "skel file/dir created 2b");
        my @g;
        @g = $pu->group("u4");
        ok($g[0] && "u4" ~~ @{$g[1]}, "user is member of u4")
            or diag explain $g[1];
        @g = $pu->group("bin");
        ok($g[0] && "u4" ~~ @{$g[1]}, "user is member of bin")
            or diag explain $g[1];
    },
);
test_setup_unix_user(
    name       => "create (undo, dry_run)",
    args       => {%args, -dry_run=>1,
                   -undo_action=>"undo", -undo_data=>$undo_data},
    status     => 200,
    posttest   => sub {
        my ($res, $name, $pu) = @_;
        my @u = $pu->user($name);
        ok($u[0], "user still exists");
        ok((-d "$tmp_dir/home"), "home dir still exists");
        ok((-f "$tmp_dir/home/.dir1/.file1"), "skel file still exists");
    },
);
test_setup_unix_user(
    name       => "create (undo)",
    args       => {%args,
                   -undo_action=>"undo", -undo_data=>$undo_data},
    status     => 200,
    exists     => 0,
    posttest   => sub {
        my ($res, $name, $pu) = @_;
        $redo_data = $res->[3]{undo_data};
        my @u = $pu->user($name);
        ok(!(-e "$tmp_dir/home"), "home dir removed");
        #ok(!(-e "$tmp_dir/home/.dir1/.file1"), "skel file removed");#implied
        my @g = $pu->group($name);
        ok(!$g[0], "group removed");
    },
);
test_setup_unix_user(
    name       => "create (redo, dry_run)",
    args       => {%args, -dry_run=>1,
                   -undo_action=>"undo", -undo_data=>$redo_data},
    status     => 200,
    exists     => 0,
);
test_setup_unix_user(
    name       => "create (redo)",
    args       => {%args,
                   -undo_action=>"undo", -undo_data=>$redo_data},
    status     => 200,
    exists     => 1,
    posttest   => sub {
        my ($res, $name, $pu) = @_;
        my @u = $pu->user($name);
        ok($u[0], "user recreated");
        #ok(XXX, "user recreated with same uid"); # needs some setup
        ok((-d "$tmp_dir/home"), "home dir recreated");
        ok((-f "$tmp_dir/home/.dir1/.file1"), "skel file recreated");
    },
);

# XXX test redo

# XXX test changed state between do -> redo

# XXX test already exist, fix membership

# XXX test rollback

# XXX test failure during rollback (dies)

# XXX test not_member_of bin

DONE_TESTING:
teardown();
