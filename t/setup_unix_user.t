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
    status     => 304,
    exists     => 0,
);
test_setup_unix_user(
    name       => "create (with create_home_dir=0)",
    args       => {name=>"u3", create_home_dir=>0},
    status     => 200,
    posttest   => sub {
        my $res = shift;
        is($res->[2]{uid}, 11, "uid");
        is($res->[2]{gid}, 11, "gid");
    },
);
goto DONE_TESTING;
test_setup_unix_user(
    name       => "create (with undo, min_new_uid, new_password, new_gecos, ".
        "new_home_dir, new_home_dir_mode, new_shell, member_of, not_member_of)",
    args       => {name=>"u6", min_new_uid=>1000, -undo_action=>"do"},
    status     => 200,
    is_file    => 1,
    posttest   => sub {
        my $res = shift;
        $undo_data = $res->[3]{undo_data};
        ok($undo_data, "there is undo data");
        is($res->[2]{uid}, 1002, "uid");
        # XXX test new_password
        # XXX test new_gecos
        # XXX test new_home_dir
        # XXX test new_home_dir_mode
        # XXX test new_shell
        # XXX test member_of
        # XXX test not_member_of
        # XXX test skel
    },
);
test_setup_unix_user(
    name       => "create (undo, dry_run)",
    args       => {name=>"g2", -dry_run=>1,
                   -undo_action=>"undo", -undo_data=>$undo_data},
    status     => 304,
);
test_setup_unix_user(
    name       => "create (undo)",
    args       => {name=>"g2",
                   -undo_action=>"undo", -undo_data=>$undo_data},
    status     => 200,
    exists     => 0,
    posttest   => sub {
        my $res = shift;
        $redo_data = $res->[3]{redo_data};
        ok($redo_data, "there is redo data");
    },
);
test_setup_unix_user(
    name       => "create (redo, dry_run)",
    args       => {name=>"g2", -dry_run=>1,
                   -undo_action=>"redo", -redo_data=>$redo_data},
    status     => 304,
    exists     => 0,
);
test_setup_unix_user(
    name       => "create (redo)",
    args       => {name=>"g2",
                   -undo_action=>"redo", -redo_data=>$redo_data},
    status     => 200,
    exists     => 1,
    posttest   => sub {
        my $res = shift;
        $undo_data = $res->[3]{undo_data};
        ok($undo_data, "there is undo data");
    },
);

# XXX test: can't redo because uid is occupied

DONE_TESTING:
teardown();
