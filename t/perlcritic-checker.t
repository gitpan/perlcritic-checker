#!/usr/bin/perl

#===============================================================================
#     REVISION:  $Id: perlcritic-checker.t 50 2011-02-24 17:56:51Z xdr.box $
#  DESCRIPTION:  Tests for perlcritic-checker.pl
#===============================================================================

use strict;
use warnings;

our $VERSION = qw($Revision: 50 $) [1];

use Readonly;
use Config;
use English qw( -no_match_vars );
use File::Spec::Functions qw( catfile path );
use File::Temp qw(tempdir);
use Carp;

#use Smart::Comments;

use FindBin qw($Bin);
FindBin::again();

use Test::More;
use Test::Command;

Readonly my $EXTRA_TESTS         => 0;
Readonly my $TESTS_PER_TEST_CASE => 3;

# Make sure the svn messages come in English
$ENV{'LC_MESSAGES'} = 'C';

#$ENV{'DONT_CLEANUP'} = 1;
#$ENV{'RUN_ONLY_LAST_TEST'} = 1;

Readonly my @REQUIRED_TOOLS => qw( svn svnadmin svnlook );

Readonly my $SCRIPT => catfile( $Bin, q{..}, 'bin', 'perlcritic-checker.pl' );
### SCRIPT: $SCRIPT
Readonly my $DATA_DIR => catfile( $Bin, 'test-cases' );
### DATA_DIR: $DATA_DIR
Readonly my $TMP_DIR => tempdir(
    'perlcritic-checker.XXXX',
    TMPDIR  => 1,
    CLEANUP => $ENV{'DONT_CLEANUP'} ? 0 : 1,
);
### TMP_DIR: $TMP_DIR

Readonly my $CONFIG_NAME   => 'perlcritic-checker.conf';
Readonly my $PROFILES_DIR  => 'perlcritic.d';
Readonly my $PRECOMMIT_DIR => 'precommit_files';

sub get_svn_version {
    my $version = `svn --version | grep "\\bversion\\b"`;
    chomp $version;

    return $version;
}

sub check_required_tools {
TOOL:
    foreach my $tool (@REQUIRED_TOOLS) {
        foreach my $path ( path() ) {
            next TOOL if -x catfile( $path, $tool );
        }

        diag("Cannot find or use '$tool' binary. PATH='$ENV{'PATH'}'");
        return 0;
    }

    return 1;
}

sub write_file {
    my $file_path    = shift;
    my $file_content = shift;

    open my $fh, '>', $file_path
        or croak "Failed to open output file '$file_path': $OS_ERROR";

    print {$fh} $file_content
        or croak "Failed to write file '$file_path': $OS_ERROR";

    close $fh
        or warn "Failed to close output file '$file_path': $OS_ERROR\n";

    return;
}

sub slurp_file {
    my $file_path = shift;

    open my $fh, '<', $file_path
        or confess "Failed to open file '$file_path': $OS_ERROR";
    my $content = do { local $RS = undef; <$fh> };
    close $fh or confess "Failed to close '$file_path': $OS_ERROR";

    return $content;
}

sub slurp_expected_data {
    my $test_id   = shift;
    my $file_name = shift;

    my $full_path = get_expected_path( $test_id, $file_name );
    my $data = slurp_file($full_path);
    chomp $data;

    return $data;
}

sub escape_pattern {
    my $pattern = shift;

    # Taken from http://www.perlmonks.org/?node_id=525815
    my $in_quote = 0;

    ## no critic (RequireExtendedFormatting, RequireLineBoundaryMatching)
    $pattern =~ s{([^\\]|\\.)}{
        if ($in_quote) {
            if ( $1 eq '\\E' ) {
                $in_quote = 0;
                q{};
            }
            else {
                quotemeta($1);
            }
        }
        else {
            if ( $1 eq '\\Q' ) {
                $in_quote = 1;
                q{};
            }
            else {
                $1;
            }
        }
    }eg;

    return $pattern;
}

sub build_regexp {
    my $pattern = shift;

    # HACK: this way we can use \Q and \E inside *_like *_not_like files
    my $escaped_pattern = escape_pattern($pattern);

    return qr/$escaped_pattern/xms;
}

sub get_repo_path {
    my $test_id = shift;

    return catfile( $TMP_DIR, $test_id, 'repo' );
}

sub get_wc_path {
    my $test_id = shift;

    return catfile( $TMP_DIR, $test_id, 'wc' );
}

sub get_expected_path {
    my $test_id   = shift;
    my $file_name = shift;

    return catfile( $DATA_DIR, $test_id, 'expected_results', $file_name );
}

sub get_log_message {
    my $test_id = shift;

    my $file_path = catfile( $DATA_DIR, $test_id, 'log_message' );
    my $log_message = slurp_file($file_path);
    chomp $log_message;

    return $log_message;
}

sub get_coverage_report_options {
    return q{} if !$ENV{'HARNESS_PERL_SWITCHES'};
    ## no critic (RequireExtendedFormatting, RequireLineBoundaryMatching)
    return q{} if $ENV{'HARNESS_PERL_SWITCHES'} !~ /Devel::Cover/;

    return $ENV{'HARNESS_PERL_SWITCHES'};
}

sub configure_pre_commit_hook {
    my $test_id = shift;

    my $config_path = catfile( $DATA_DIR, $test_id, $CONFIG_NAME );
    my $hook_name = catfile( get_repo_path($test_id), 'hooks', 'pre-commit' );

    my $coverage_report_opts = get_coverage_report_options();

    my $hook_content = <<"END_HOOK_CONTENT";
#!/bin/bash

REPOS="\$1"
TXN="\$2"
$Config{'perlpath'} $coverage_report_opts $SCRIPT --repository "\$REPOS" --config "$config_path" --transaction "\$TXN" || exit 1
exit 0
END_HOOK_CONTENT

    write_file( $hook_name, $hook_content );

    ## no critic (ProhibitMagicNumbers)
    chmod 0755, $hook_name
        or croak "Cannot chmod 755 file '$hook_name': $OS_ERROR";

    return;
}

sub setup_repo {
    my $test_id = shift;

    my $repo_path = get_repo_path($test_id);
    my $wc_path   = get_wc_path($test_id);

    my $test_dir = catfile( $TMP_DIR, $test_id );

    my $perlcritic_d_link_from
        = catfile( $repo_path, 'hooks', $PROFILES_DIR );
    my $perlcritic_d_link_to = catfile( $DATA_DIR, $test_id, $PROFILES_DIR );

    my $command = <<"END_COMMAND";
mkdir '$test_dir' &&
svnadmin create '$repo_path' &&
svn checkout 'file://$repo_path' '$wc_path' &&
ln --verbose --symbolic '$perlcritic_d_link_to' '$perlcritic_d_link_from'
END_COMMAND
    ### create svn repo command: $command

    system $command;
    if ( $CHILD_ERROR != 0 ) {
        confess "Cannot create SVN repository. Command: '$command'";
    }

    precommit_files($test_id);
    configure_pre_commit_hook($test_id);

    return;
}

sub precommit_files {
    my $test_id = shift;

    my $wc_path   = get_wc_path($test_id);
    my $from_path = catfile( $DATA_DIR, $test_id, $PRECOMMIT_DIR );
    my $to_path   = catfile( $wc_path, $PRECOMMIT_DIR );

    return if !-d $from_path;

    my $command = <<"END_COMMAND";
cp --recursive --verbose '$from_path' '$wc_path' &&
find '$to_path' -name '.svn' -type d | xargs rm -frdv &&
mv --verbose $to_path/* '$wc_path' &&
rmdir '$to_path' &&
pushd '$wc_path' &&
svn add * &&
svn commit -m "pre-commit files" *
popd
END_COMMAND
    ### pre-commit files to svn repo command: $command

    system $command;
    if ( $CHILD_ERROR != 0 ) {
        confess
            "Cannot pre-commit files to SVN repository. Command '$command'";
    }

    return;
}

sub add_files {
    my $test_id = shift;

    my $wc_path       = get_wc_path($test_id);
    my $from_path     = catfile( $DATA_DIR, $test_id, 'files' );
    my $wc_files_path = catfile( $wc_path, 'files' );

    my $command = <<"END_COMMAND";
cp --recursive --verbose '$from_path' '$wc_path' &&
find '$wc_files_path' -name '.svn' -type d | xargs rm -frdv &&
mv --verbose $wc_files_path/* '$wc_path' &&
rmdir '$wc_files_path' &&
pushd '$wc_path' &&
svn --quiet add * &&
popd
END_COMMAND
    ### add files to svn repo command: $command

    system $command;
    if ( $CHILD_ERROR != 0 ) {
        confess "Cannot add files to SVN repository. Command: '$command'";
    }

    return;
}

sub commit_files {
    my $test_id = shift;

    my $wc_path     = get_wc_path($test_id);
    my $log_message = get_log_message($test_id);

    my $command = <<"END_COMMAND";
pushd '$wc_path' &&
svn commit * -m "$log_message" &&
popd
END_COMMAND
    ### commit files to svn repo command: $command

    my $result = Test::Command->new( cmd => $command );

    return $result;
}

sub set_test_plan {
    my $number_of_test_cases = shift;

    plan tests => $TESTS_PER_TEST_CASE * $number_of_test_cases + $EXTRA_TESTS;

    return;
}

sub get_test_ids {

    # Find all dir names consisting of three digits
    my @test_ids = sort map { $_ =~ /(?<!\d)(\d{3})\z/xms ? $1 : () }
        grep { -d $_ } glob "$DATA_DIR/*";

    # Setting RUN_ONLY_LAST_TEST is useful when adding new tests
    return ( $ENV{'RUN_ONLY_LAST_TEST'} ? $test_ids[-1] : @test_ids );
}

sub get_expected_status {
    my $test_id = shift;

    my $status = slurp_expected_data( $test_id, 'status' );

    if ( $status ne 'ok' and $status ne 'fail' ) {
        confess "Invalid status '$status': Use either 'ok' or 'fail'";
    }

    return $status;
}

sub get_test_description {
    my $test_id = shift;

    my $file_name = catfile( $DATA_DIR, $test_id, 'description' );
    my $description = slurp_file($file_name);
    chomp $description;

    return $description;
}

sub check_output {
    my $test_id     = shift;
    my $result      = shift;
    my $output_type = shift;
    my $label       = shift;

    my $like     = $output_type . '_like';
    my $not_like = $output_type . '_not_like';

    if ( -e get_expected_path( $test_id, $like ) ) {
        my $pattern = slurp_expected_data( $test_id, $like );
        my $like_method = $output_type . '_like';

        $result->$like_method( build_regexp($pattern),
            "$label: check $output_type matches regexp" );
    }
    elsif ( -e get_expected_path( $test_id, $not_like ) ) {
        my $pattern = slurp_expected_data( $test_id, $not_like );
        my $unlike_method = $output_type . '_unlike';

        $result->$unlike_method( build_regexp($pattern),
            "$label: check $output_type doesn't match regexp" );
    }
    else {
        confess
            "Neither '$like' nor '$not_like' files found for test $test_id";
    }

    return;
}

sub check_status {
    my $test_id = shift;
    my $result  = shift;
    my $label   = shift;

    my $expected_status = get_expected_status($test_id);
    if ( $expected_status eq 'ok' ) {
        $result->exit_is_num( 0, "$label: check commit is ok" );
    }
    else {
        $result->exit_cmp_ok( q{!=}, 0, "$label: check commit is failed" );
    }

    return;
}

sub check_result {
    my $test_id = shift;
    my $result  = shift;

    my $test_description = get_test_description($test_id);
    my $label            = "[$test_id] $test_description";

    check_status( $test_id, $result, $label );
    check_output( $test_id, $result, 'stdout', $label );
    check_output( $test_id, $result, 'stderr', $label );

    return;
}

sub test_perlcritic_checker {
    my @test_ids = get_test_ids();
    ### test_ids: @test_ids

    set_test_plan( scalar @test_ids );

    foreach my $test_id (@test_ids) {
        setup_repo($test_id);
        add_files($test_id);

        my $result = commit_files($test_id);

        check_result( $test_id, $result );
    }

    return;
}

sub run_tests {
    if ( check_required_tools() ) {
        diag( 'svn version: ' . get_svn_version() );
        test_perlcritic_checker();
    }
    else {
        plan skip_all => 'Cannot find or use all required svn binaries';
    }

    return;
}

run_tests();

# Workaround for bug in File::Temp:
# - http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=479317
# - http://rt.cpan.org/Public/Bug/Display.html?id=35779
sub END {
    chdir q{/};
}
