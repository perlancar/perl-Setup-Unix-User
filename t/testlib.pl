use 5.010;
use strict;
use warnings;

use File::chdir;
use File::Path qw(remove_tree);
use File::Slurp;
use File::Temp qw(tempdir);
use Setup::Unix::Group qw(setup_unix_group);
#use Setup::Unix::User  qw(setup_unix_user);
use Test::More 0.96;
use Test::Perinci::Tx::Manager qw(test_tx_action);

my $passwd_path;
my $shadow_path;
my $group_path;
my $gshadow_path;

sub setup_data {
    $passwd_path = "$::tmp_dir/passwd";
    unlink $passwd_path;
    write_file($passwd_path, <<'_');
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/bin:/bin/sh
daemon:x:2:2:daemon:/sbin:/bin/sh
u1:x:1000:1000::/home/u1:/bin/bash
u2:x:1001:1001::/home/u2:/bin/bash
_

    $shadow_path = "$::tmp_dir/shadow";
    unlink $shadow_path;
    write_file($shadow_path, <<'_');
root:*:14607:0:99999:7:::
bin:*:14607:0:99999:7:::
daemon:*:14607:0:99999:7:::
u1:*:14607:0:99999:7:::
u2:*:14607:0:99999:7:::
_

    $group_path = "$::tmp_dir/group";
    unlink $group_path;
    write_file($group_path, <<'_');
root:x:0:
bin:x:1:
daemon:x:2:
nobody:x:111:
u1:x:1000:u1
u2:x:1002:u2
_

    $gshadow_path = "$::tmp_dir/gshadow";
    unlink $gshadow_path;
    write_file($gshadow_path, <<'_');
root:::
bin:::
daemon:::
nobody:!::
u1:!::
u2:!::u1
_

    # setup skeleton
    remove_tree "$::tmp_dir/skel";
    mkdir("$::tmp_dir/skel");
    mkdir("$::tmp_dir/skel/.dir1");
    write_file("$::tmp_dir/skel/.dir1/.file1", "file 1");
    write_file("$::tmp_dir/skel/.file2", "file 2");
    write_file("$::tmp_dir/skel/.file3", "file 3");
}

sub setup {
    plan skip_all => "No /etc/passwd, probably not Unix system"
        unless -f "/etc/passwd";

    $::tmp_dir = tempdir(CLEANUP => 1);
    $CWD = $::tmp_dir;

    setup_data();
    note "tmp dir = $::tmp_dir";
}

sub teardown {
    done_testing();
    if (Test::More->builder->is_passing) {
        #note "all tests successful, deleting temp files";
        $CWD = "/";
    } else {
        diag "there are failing tests, not deleting temp files";
    }
}

sub _test_setup_unix_group_or_user {
    my ($which, %tsuargs) = @_;

    my %ttaargs;
    for (grep {!/after_do|after_undo/} keys %tsuargs) {
        $ttaargs{$_} = $tsuargs{$_};
    }

    $ttaargs{tmpdir} = $::tmp_dir;
    $ttaargs{reset_state} = sub { setup_data() };
    $ttaargs{f} = $which eq 'group' ?
        'Setup::Unix::Group::setup_unix_group' :
            'Setup::Unix::User::setup_unix_user';
    my %fargs = %{ $tsuargs{args} };
    $fargs{passwd_path}  = $passwd_path;
    $fargs{group_path}   = $group_path;
    $fargs{shadow_path}  = $shadow_path;
    $fargs{gshadow_path} = $gshadow_path;
    $ttaargs{args} = \%fargs;

    $::pu = Passwd::Unix::Alt->new(
        passwd  => $passwd_path,
        group   => $group_path,
        shadow  => $shadow_path,
        gshadow => $gshadow_path,
    );

    for my $ak (qw/after_do after_undo/) {
        my $a = $tsuargs{$ak};
        next unless $a;
        $ttaargs{$a} = sub {
            my @e;
            my $name = $fargs{name};
            if ($which eq 'user') {
                @e = $::pu->user($name);
            } else {
                @e = $::pu->group($name);
            }
            #note explain \@e;

            my $exists = $e[0] ? 1:0;

            if ($a->{exists} // 1) {
                ok($exists, "exists") or return;
                if ($which eq 'user') {
                    if (defined $a->{uid}) {
                        is($e[1], $a->{uid}, "uid");
                    }
                    if (defined $a->{gid}) {
                        is($e[2], $a->{gid}, "gid");
                    }
                } else {
                    if (defined $a->{gid}) {
                        is($e[0], $a->{gid}, "gid");
                    }
                }
            } else {
                ok(!$exists, "does not exist");
            }

            if ($which eq 'user') {
                if ($a->{member_of}) {
                    my @g;
                    for my $g (@{ $a->{member_of} }) {
                        @g = $::pu->group($g);
                        ok($g[0] && $name ~~ @{$g[1]},
                           "user $name is member of $g")
                            or note "members of group $g: " .
                                join(" ", @{$g[1]});
                    }
                }
                if ($a->{not_member_of}) {
                    my @g;
                    for my $g (@{ $a->{not_member_of} }) {
                        @g = $::pu->group($g);
                        ok(!$g[0] || !($name ~~ @{$g[1]}),
                           "user $name is not member of $g")
                            or note "members of group $g: " .
                                join(" ", @{$g[1]});
                    }
                }
            }

            if ($a->{extra}) {
                $a->{extra}->();
            }
        };
    }

    test_tx_action(%ttaargs);
}

sub test_setup_unix_group { _test_setup_unix_group_or_user('group', @_) }

sub test_setup_unix_user  { _test_setup_unix_group_or_user('user',  @_) }

1;
