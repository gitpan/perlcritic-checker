#!/usr/bin/perl

#===============================================================================
#     REVISION:  $Id: perlcritic-checker.t 7 2010-07-19 13:31:50Z xdr.box $
#  DESCRIPTION:  Tests for perlcritic-checker.pl script
#===============================================================================

use strict;
use warnings;

our $VERSION = qw($Revision: 7 $) [1];

use FindBin qw($Bin);
FindBin::again();

use Readonly;
use File::Spec::Functions qw/catfile path/;
use File::Copy::Recursive qw(rcopy);
use File::Copy;
use File::Basename;
use Carp;
use Cwd;
use English qw(-no_match_vars);
use File::Temp qw/tempdir/;

use Test::More tests => 46;
use Test::Command;

#use Smart::Comments;

Readonly my $EXIT_OK   => 0;
Readonly my $EXIT_FAIL => 1;
Readonly my $EMPTY_STR => q{};

# Make sure the svn messages come in English
$ENV{'LC_MESSAGES'} = 'C';
$ENV{'PATH'}        = '/usr/local/bin:/usr/bin:/bin';

# Uncomment this to keep test repo after finish
#$ENV{'REPO_CLEANUP'} = 0;

#-------------------------------------------------------------------------------
#  Create temporary directory for svn repository & working copy.
#  Install perlcritic-checker svn hook, deploy test configs.
#-------------------------------------------------------------------------------
sub create_repo {
    my $cleanup = exists $ENV{'REPO_CLEANUP'} ? $ENV{'REPO_CLEANUP'} : 1;
    my $tmpdir = tempdir( 't.XXXX', DIR => getcwd(), CLEANUP => $cleanup );

    my $result = system <<"EOS";
svnadmin create '$tmpdir/repo'                                                            &&
svn co -q file://$tmpdir/repo '$tmpdir/wc'                                                &&
cp '$Bin/../bin/perlcritic-checker.pl' '$tmpdir/repo/hooks'                               &&
mkdir '$tmpdir/repo/hooks/perlcritic.d'                                                   &&
sh -c "cp \"$Bin/test-data/*.conf\" '$tmpdir/repo/hooks'"                                 &&
sh -c "cp \"$Bin/test-data/perlcritic.d/*.conf\" '$tmpdir/repo/hooks/perlcritic.d'"
EOS

    croak "Failed to create test repository in '$tmpdir'" if $result != 0;

    return $tmpdir;
}

#-------------------------------------------------------------------------------
#  Write custom pre-commit hook script on fly
#-------------------------------------------------------------------------------
sub configure_hook {
    my $tmpdir = shift;
    my $config = shift;    # perlcritic-checker config

    my $hook_content = <<"END_SCRIPT";
#!/bin/bash

REPOS="\$1"
TXN="\$2"
\$REPOS/hooks/perlcritic-checker.pl --repository "\$REPOS" --config "\$REPOS/hooks/$config" --transaction "\$TXN" || exit 1
exit 0
END_SCRIPT

    my $file_name = "$tmpdir/repo/hooks/pre-commit";
    write_to_file( $file_name, $hook_content );

    ## no critic (ProhibitMagicNumbers)
    chmod 0755, $file_name
        or croak "Cannot chmod 755 file '$file_name': $OS_ERROR";

    return;
}

#-------------------------------------------------------------------------------
#  Save data to the file
#-------------------------------------------------------------------------------
sub write_to_file {
    my $file_path    = shift;
    my $file_content = shift;

    open my $F, '>', $file_path
        or croak "Failed to open output file '$file_path': $OS_ERROR";

    print {$F} $file_content
        or croak "Cannot write to file '$file_path': $OS_ERROR";

    close $F
        or warn "Failed to close output file '$file_path': $OS_ERROR\n";

    return;
}

#-------------------------------------------------------------------------------
#  Copy file for sample-files dir to the working copy
#-------------------------------------------------------------------------------
sub copy_file_to_wc {
    my $tmpdir    = shift;
    my $file_name = shift;
    my $save_as   = shift || $file_name;

    my $src = "$Bin/test-data/sample-files/$file_name";
    my $dst = "$tmpdir/wc/$save_as";

    rcopy( $src, $dst ) or croak "Cannot copy '$src' -> '$dst': $OS_ERROR";
    chdir dirname($dst);

    return;
}

#-------------------------------------------------------------------------------
#  Handy functions get .stdout and .stderr files for a given file
#-------------------------------------------------------------------------------
sub get_stdout_for {
    my $file = shift;

    return "$Bin/test-data/sample-files/$file.stdout";
}

sub get_stderr_for {
    my $file = shift;

    return "$Bin/test-data/sample-files/$file.stderr";
}

#-------------------------------------------------------------------------------
#  Create repository
#-------------------------------------------------------------------------------
my $tmpdir = create_repo();
### tmpdir: $tmpdir

#-------------------------------------------------------------------------------
#  Test 1: add good file
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'progressive_yes_allow_nocritic_yes.conf' );
    copy_file_to_wc( $tmpdir, 'test1-1.pl', 'test1.pl' );

    my $test_name = 'add + ci test1.pl (version 1, no violations)';
    my $cmd       = Test::Command->new(
        cmd => q{svn add 'test1.pl' && svn ci -m 'commit1' test1.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_OK, "$test_name: exit code is OK" );
    $cmd->stdout_is_file( get_stdout_for('test1-1.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_is_file( get_stderr_for('test1-1.pl'),
        "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 2: introduce violations to the previous file: commit should fail
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'progressive_yes_allow_nocritic_yes.conf' );
    copy_file_to_wc( $tmpdir, 'test1-2.pl', 'test1.pl' );

    my $test_name = 'ci test1.pl (version 2, with violations)';
    my $cmd = Test::Command->new( cmd => q{svn ci -m 'commit2' test1.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_FAIL, "$test_name: exit code is FAIL" );
    $cmd->stdout_is_file( get_stdout_for('test1-2.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_is_file( get_stderr_for('test1-2.pl'),
        "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 3: force commit with a special emergency comment
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'progressive_yes_allow_nocritic_yes.conf' );
    copy_file_to_wc( $tmpdir, 'test1-2.pl', 'test1.pl' );

    my $test_name
        = q{ci -m 'Please!!!' test1.pl (version 2, with violations and emergency comment)};
    my $cmd = Test::Command->new( cmd => q{svn ci -m 'Please!!!' test1.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_OK, "$test_name: exit code is OK" );
    $cmd->stdout_is_file( get_stdout_for('test1-2-NO-CRITIC.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_is_file( get_stderr_for('test1-2-NO-CRITIC.pl'),
        "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 4: emergency commits are not allowed, commit with violations should fail
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'progressive_yes_allow_nocritic_no.conf' );
    copy_file_to_wc( $tmpdir, 'test1-3.pl', 'test1.pl' );

    my $test_name
        = q{ci -m 'NO CRITIC' test1.pl (version 3, with violations and emergency comment)};
    my $cmd = Test::Command->new( cmd => q{svn ci -m 'NO CRITIC' test1.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_FAIL, "$test_name: exit code is FAIL" );
    $cmd->stdout_is_file( get_stdout_for('test1-3.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_is_file( get_stderr_for('test1-3.pl'),
        "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 5: turn off progressive mode. commit should fail due to existing violations
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'progressive_no_allow_nocritic_yes.conf' );
    copy_file_to_wc( $tmpdir, 'test1-4.pl', 'test1.pl' );

    my $test_name
        = q{ci -m '' test1.pl (version 4, non-progressive mode, with only existing violations)};
    my $cmd = Test::Command->new( cmd => q{svn ci -m '' test1.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_FAIL, "$test_name: exit code is FAIL" );
    $cmd->stdout_is_file( get_stdout_for('test1-4.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_is_file( get_stderr_for('test1-4.pl'),
        "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 6: force previous commit with emergency comment
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'progressive_no_allow_nocritic_yes.conf' );
    copy_file_to_wc( $tmpdir, 'test1-4.pl', 'test1.pl' );

    my $test_name
        = q{ci -m 'NO CRITIC: emergency bugfix' test1.pl (version 4, non-progressive mode, with only existing violations and emergency comment)};
    my $cmd = Test::Command->new(
        cmd => q{svn ci -m 'NO CRITIC: emergency bugfix' test1.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_OK, "$test_name: exit code is OK" );
    $cmd->stdout_is_file( get_stdout_for('test1-4-NO-CRITIC.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_is_file( get_stderr_for('test1-4-NO-CRITIC.pl'),
        "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 7: non-progressive mode, emergency comments are not allowed.
#  Commit with already existing should fail despite of any "special"
#  comments.
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'progressive_no_allow_nocritic_no.conf' );
    copy_file_to_wc( $tmpdir, 'test1-5.pl', 'test1.pl' );

    my $test_name
        = q{ci -m 'NO CRITIC: emergency bugfix' test1.pl (version 5, non-progressive mode, with only existing violations, emergency comments are not allowed)};
    my $cmd = Test::Command->new(
        cmd => q{svn ci -m 'NO CRITIC: emergency bugfix' test1.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_FAIL, "$test_name: exit code is FAIL" );
    $cmd->stdout_is_file( get_stdout_for('test1-5.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_is_file( get_stderr_for('test1-5.pl'),
        "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 8: file with violations, minimal config.
#  Commit should succeed becasue there are no rules defined in
#  the config
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'minimal.conf' );
    copy_file_to_wc( $tmpdir, 'test2-1.pl', 'test2.pl' );

    my $test_name
        = q{add + ci -m '' test2.pl (version 1, with violations, minimal config with no matching rules)};
    my $cmd = Test::Command->new(
        cmd => q{svn add test2.pl && svn ci -m '' test2.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_OK, "$test_name: exit code is OK" );
    $cmd->stdout_is_file( get_stdout_for('test2-1.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_is_file( get_stderr_for('test2-1.pl'),
        "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 9: Invalid config file: b0rken_a_hef.conf
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'b0rken_a_hef.conf' );
    copy_file_to_wc( $tmpdir, 'test3-1.pl', 'test3.pl' );

    my $test_name
        = q{add + ci -m '' test3.pl (version 1, without violations, broken config - not a hash ref)};
    my $cmd = Test::Command->new(
        cmd => q{svn add test3.pl && svn ci -m '' test3.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_FAIL, "$test_name: exit code is FAIL" );
    $cmd->stdout_is_file( get_stdout_for('test3-1-broken-1.pl'),
        "$test_name: check STDOUT" );
    ## no critic (RequireExtendedFormatting)
    $cmd->stderr_like( qr{b0rken_a_hef[.]conf - HASH ref was expected$}ms,
        "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 10: Invalid config file: b0rken_not_true.conf
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'b0rken_not_true.conf' );
    copy_file_to_wc( $tmpdir, 'test3-1.pl', 'test3.pl' );

    my $test_name
        = q{ci -m '' test3.pl (version 1, without violations, broken config - not eval to true)};
    my $cmd = Test::Command->new( cmd => q{svn ci -m '' test3.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_FAIL, "$test_name: exit code is FAIL" );
    $cmd->stdout_is_file( get_stdout_for('test3-1-broken-2.pl'),
        "$test_name: check STDOUT" );
    ## no critic (RequireExtendedFormatting)
    $cmd->stderr_like( qr{^Bad file format:}ms, "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 11: Invalid config file: b0rken_total_rubbish.conf
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'b0rken_total_rubbish.conf' );
    copy_file_to_wc( $tmpdir, 'test3-1.pl', 'test3.pl' );

    my $test_name
        = q{ci -m '' test3.pl (version 1, without violations, broken config - total rubbish)};
    my $cmd = Test::Command->new( cmd => q{svn ci -m '' test3.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_FAIL, "$test_name: exit code is FAIL" );
    $cmd->stdout_is_file( get_stdout_for('test3-1-broken-3.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_like(
        qr{
        ^
        Semicolon[ ]seems[ ]to[ ]be[ ]missing.*
        Cannot[ ]parse.*
    }xms, "$test_name: check STDERR"
    );
}

#-------------------------------------------------------------------------------
#  Test 12: test critic with max_violations limit in non-progressive mode
#  Commit should fail due to existing violations
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'progressive_no_max_violations_50.conf' );
    copy_file_to_wc( $tmpdir, 'test4-1.pl', 'test4.pl' );

    my $test_name
        = q{add + commit test4.pl (max_violations=50, non-progressive mode)};
    my $cmd = Test::Command->new(
        cmd => q{svn add test4.pl && svn ci -m '' test4.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_FAIL, "$test_name: exit code is FAIL" );
    $cmd->stdout_is_file( get_stdout_for('test4-1.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_is_file( get_stderr_for('test4-1.pl'),
        "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 13: the same file as above but there is no max_violations limit.
#  Commit should fail, violation list shouldn't be trimmed.
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir, 'progressive_no_allow_nocritic_no.conf' );

    my $test_name
        = q{commit test4.pl (no max_violations limit, non-progressive mode)};
    my $cmd = Test::Command->new( cmd => q{svn ci -m '' test4.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_FAIL, "$test_name: exit code is FAIL" );
    $cmd->stdout_is_file(
        get_stdout_for('test4-1-no_max_violations-limit.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_is_file(
        get_stderr_for('test4-1-no_max_violations-limit.pl'),
        "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 14: test critic with max_violations limit in progressive mode
#  with allowed emergency commits.
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir,
        'progressive_yes_allow_no_critic_yes_max_violations_50.conf' );
    copy_file_to_wc( $tmpdir, 'test5-1.pl', 'test5.pl' );

    my $test_name
        = q{add + ci test5-1.pl (max_violations=50, progressive mode, allow emergency commits)};
    my $cmd = Test::Command->new(
        cmd => q{svn add test5.pl && svn ci -m '' test5.pl} );

    $cmd->run();
    $cmd->exit_is_num( $EXIT_OK, "$test_name: exit code is OK" );

    copy_file_to_wc( $tmpdir, 'test5-2.pl', 'test5.pl' );

    $test_name
        = q{ci test5-2.pl (second version with violations, max_violations=50, progressive mode, allow emergency commits)};
    $cmd = Test::Command->new( cmd => q{svn ci -m '' test5.pl} );
    $cmd->run();

    $cmd->exit_is_num( $EXIT_FAIL, "$test_name: exit code is FAIL" );
    $cmd->stdout_is_file( get_stdout_for('test5-2.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_is_file( get_stderr_for('test5-2.pl'),
        "$test_name: check STDERR" );
}

#-------------------------------------------------------------------------------
#  Test 15: test critic on the same file as above but without max_violations limit,
#  in progressive mode and with allowed emergency commits.
#-------------------------------------------------------------------------------
{
    configure_hook( $tmpdir,
        'progressive_yes_allow_no_critic_yes_without_max_violations.conf' );

    my $test_name
        = q{ci test5-2.pl (second version with violations,without max_violations, progressive mode, allow emergency commits)};
    my $cmd = Test::Command->new( cmd => q{svn ci -m '' test5.pl} );
    $cmd->run();

    $cmd->exit_is_num( $EXIT_FAIL, "$test_name: exit code is FAIL" );
    $cmd->stdout_is_file( get_stdout_for('test5-2-without-max_violations.pl'),
        "$test_name: check STDOUT" );
    $cmd->stderr_is_file( get_stderr_for('test5-2-without-max_violations.pl'),
        "$test_name: check STDERR" );
}

# Workaround for bug in File::Temp:
# - http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=479317
# - http://rt.cpan.org/Public/Bug/Display.html?id=35779
sub END {
    chdir q{/};
}

