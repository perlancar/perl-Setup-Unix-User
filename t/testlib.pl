use 5.010;
use strict;
use warnings;

use File::Slurp;
use File::Temp qw(tempfile);
use Setup::UnixGroup qw(setup_unix_group);
#use Setup::UnixUser qw(setup_unix_user);
use Test::More 0.96;

my $passwd_path;
my $group_path;

sub setup {
    my $fh;
    ($fh, $passwd_path) = tempfile();
    write_file($passwd_path, <<'_');
_

    ($fh, $group_path) = tempfile();
    write_file($group_path, <<'_');
root:x:0:
bin:x:1:
daemon:x:2:
sys:x:3:
adm:x:4:
tty:x:5:s1
disk:x:6:
lp:x:7:
mem:x:8:
kmem:x:9:
wheel:x:10:s1
mail:x:12:
news:x:13:
uucp:x:14:
man:x:15:
polkituser:x:16:
haldaemon:x:17:
rpm:x:18:
floppy:x:19:
games:x:20:
tape:x:21:
cdrom:x:22:s1,s2
utmp:x:24:
shadow:x:25:
chkpwd:x:26:
auth:x:27:
usb:x:43:
vcsa:x:69:
ntp:x:71:
sshd:x:72:
gdm:x:73:
mpd:x:74:
apache:x:75:
mailnull:x:76:
smmsp:x:77:
cdwriter:x:80:
audio:x:81:u1,u2,u3,u4
video:x:82:u1,u2
dialout:x:83:
users:x:100:u1,u2
messagebus:x:101:
avahi:x:102:
avahi-autoipd:x:103:
xgrp:x:104:
ntools:x:105:
ctools:x:106:
rtkit:x:107:
htdig:x:108:
slocate:x:109:
lpadmin:x:110:
nobody:x:111:
u1:x:1000:u1
u2:x:1001:u2
guest:x:61000:
nogroup:x:65534:
_

    diag "temp passwd file = $passwd_path";
    diag "temp group file = $group_path";
}

sub teardown {
    done_testing();
    if (Test::More->builder->is_passing) {
        #diag "all tests successful, deleting temp files";
        unlink $passwd_path;
        unlink $group_path;
    } else {
        diag "there are failing tests, not deleting temp files";
    }
}

sub _test_setup_unix_group_or_file {
    my ($which, %args) = @_;
    subtest "$args{name}" => sub {

        my %setup_args = %{ $args{args} };
        my $name = $setup_args{name};
        my $res;
        eval {
            if ($which eq 'user') {
                $setup_args{_passwd_file_path} = $passwd_path;
                $res = setup_unix_user(%setup_args);
            } else {
                $setup_args{_group_file_path} = $group_path;
                $res = setup_unix_group(%setup_args);
            }
        };
        my $eval_err = $@;

        if ($args{dies}) {
            ok($eval_err, "dies");
        } else {
            ok(!$eval_err, "doesn't die") or diag $eval_err;
        }

        #diag explain $res;
        if ($args{status}) {
            is($res->[0], $args{status}, "status $args{status}")
                or diag explain($res);
        }

        my $uobj;
        my @e;
        if ($which eq 'user') {
            $uobj = Unix::PasswdFile->new($passwd_path, locking=>"none", mode=>"r")
                or die "Can't create Unix::PasswdFile object: $!";
            @e = $uobj->user($name)
        } else {
            $uobj = Unix::GroupFile->new($group_path, locking=>"none", mode=>"r")
                or die "Can't create Unix::GroupFile object: $!";
            @e = $uobj->group($name)
        }

        my $exists = $e[0] ? 1:0;

        if ($args{exists} // 1) {
            ok($exists, "exists") or return;

        } else {
            ok(!$exists, "does not exist");
        }

        if ($args{posttest}) {
            $args{posttest}->($res, $name);
        }
    };
}

sub test_setup_unix_group { _test_setup_unix_group_or_file('group', @_) }

sub test_setup_unix_user  { _test_setup_unix_group_or_file('user',  @_) }

1;
