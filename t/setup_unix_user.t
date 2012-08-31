#!perl

use 5.010;
use strict;
use warnings;

use FindBin '$Bin';
use lib $Bin, "$Bin/t";

use Test::More 0.96;
require "testlib.pl";

use vars qw($tmp_dir);

setup();

test_setup_unix_user(
    name          => "create with create_home_dir=0",
    args          => {user=>"u3", create_home_dir=>0},
    after_undo    => {exists=>0},
    after_do      => {
        uid=>1002, gid=>1001, member_of=>[qw/u3/],
        extra => sub {
            ok(!(-d "$tmp_dir/home"), "home not created");
        }
    },
);
goto DONE_TESTING;

my %args = (
    name              => "u4",
    min_new_uid       => 2000,
    new_password      => "123",
    new_gecos         => "user 4",
    new_home_dir      => "$tmp_dir/home",
    new_home_dir_mode => 0750,
    new_shell         => "/bin/shell",
    primary_group     => "bin",
    member_of         => ["bin", "u1", "test"],
    skel_dir          => "$tmp_dir/skel",
);

test_setup_unix_user(
    name          => "create",
    args          => {%args},
    after_undo    => {exists=>0},
    after_do      => {
        uid   => 1002,
        gid   => 1,
        member_of     => [qw/bin u1/],
        not_member_of => [qw/u4 test/],
        extra => sub {
            my @u = $pu->user("u4");
            # XXX test new_password
            is($u[3], "user 4", "new_gecos");
            is($u[4], "$tmp_dir/home", "new_home_dir");
            is($u[5], "/bin/shell", "new_shell");
            ok((-d "$tmp_dir/home"), "home dir created");
            ok((-f "$tmp_dir/home/.dir1/.file1"), "skel file/dir created 1a");
            is(read_file("$tmp_dir/home/.dir1/.file1", err_mode=>'quiet'),
               "file 1", "skel file/dir created 1b");
            ok((-f "$tmp_dir/home/.file2"), "skel file/dir created 2a");
            is(read_file("$tmp_dir/home/.file2", err_mode=>'quiet'), "file 2",
               "skel file/dir created 2b");
        },
    },
);
# users: u1=1000, u2=1001, u3=3, u4=1002

test_setup_unix_user(
    name          => "create non-existing with should_already_exist=1 -> fail",
    args          => {user=>"u5", create_home_dir=>0, should_already_exist=>1},
    after_undo    => {exists=>0},
    dry_do_error  => 412,
);

test_setup_unix_user(
    name          => "create, failed getting unused uid",
    args          => {user=>"u5", create_home_dir=>0,
                      min_new_uid=>1000, max_new_uid=>1002},
    after_undo    => {exists=>0},
    do_error      => 500,
);

test_setup_unix_user(
    name          => "create existing with should_already_exist=1 -> noop",
    args          => {%args, should_already_exist=>1},
    after_undo    => {},
    after_do      => {},
);

{
    local $args{member_of}     = ["daemon"];
    local $args{not_member_of} = ["u1"];
    local $args{primary_group};
    test_setup_unix_user(
        name          => "fix membership",
        args          => {%args},
        after_undo    => {member_of=>[qw/u1/],     not_member_of=>[qw/daemon/]},
        after_do      => {member_of=>[qw/daemon/], not_member_of=>[qw/u1/]},
    );
}

test_setup_unix_user(
    name          => "changed state between do and undo",
    args          => {user=>"u5", new_home_dir=>"$tmp_dir/u5",
                      min_new_uid=>1000, member_of=>["bin"],
                      skel_dir=>"$tmp_dir/skel"},
    after_undo    => {exists=>0},
    after_do      => {},
    set_state1    => sub {
        write_file("$tmp_dir/u5/x", "test");   # file added to user's home
        unlink "$tmp_dir/u5/.file2";           # file removed
        write_file("$tmp_dir/u5/.file3", "x"); # file modified
    },
    check_state1  => sub {
        ok((-d "$tmp_dir/u5"), "homedir not removed because not empty");
        ok((-f "$tmp_dir/u5/x"), "file added by us not removed");
        ok(!(-e "$tmp_dir/u5/.dir1"), "file added by do removed");
        ok((-f "$tmp_dir/u5/.file3"), "file modified by us not removed");
    },
);
# users: u1=1000, u2=1001, u3=3, u4=1002, u5=1003

DONE_TESTING:
teardown();
