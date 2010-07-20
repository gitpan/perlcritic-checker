#!/usr/bin/perl

#
# $Id: perlcritic-checker.pl 11 2010-07-19 15:34:19Z xdr.box $
#
# Subversion pre-commit hook script for checking
# Perl-code using Perl::Critic module
#
# Copyright (C) 2009-2010 Alexander Simakov, <xdr (dot) box (at) Google Mail>
# http://alexander-simakov.blogspot.com/
# http://code.google.com/p/perlcritic-checker
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
# See also:  http://perlcritic.com/
# Read also: Damian Conway, "Perl Best Practices"
#

use strict;
use warnings;

our $VERSION = '1.2.1';

use Readonly;
use English qw(-no_match_vars);
use List::MoreUtils qw(last_value);
use File::Spec::Functions qw(catfile path rootdir file_name_is_absolute);
use Carp;
use Pod::Usage;
use Getopt::Long 2.24 qw(:config no_auto_abbrev no_ignore_case);
use SVN::Look;
use Perl::Critic;
use Perl::Critic::Utils qw(:severities);
use Term::ANSIColor;

#use Smart::Comments;

#-------------------------------------------------------------------------------
#  Handy constants
#-------------------------------------------------------------------------------
Readonly my $ALLOW_COMMIT => 0;
Readonly my $DENY_COMMIT  => 1;
Readonly my $YES          => 1;
Readonly my $NO           => 0;
Readonly my $EMPTY_STR    => q{};

my $Options;    ## no critic (ProhibitMixedCaseVars)
my $Config;     ## no critic (ProhibitMixedCaseVars)

#-------------------------------------------------------------------------------
#  Parse and check command-line options
#-------------------------------------------------------------------------------
sub get_options {
    my $options = {};

    my $options_okay = GetOptions(
        $options,
        'revision|r=i',       # Revision ID (for testing purposes)
        'transaction|t=s',    # Transaction ID
        'repository|p=s',     # Path to SVN repository
        'config|c=s',         # Path to config file
        'help|?',             # Show brief help message
        'man',                # Show full documentation
    );

    # More meaningfull names for pod2usage's -verbose parameter
    Readonly my $SHOW_USAGE_ONLY         => 0;
    Readonly my $SHOW_BRIEF_HELP_MESSAGE => 1;
    Readonly my $SHOW_FULL_MANUAL        => 2;

    # Show appropriate help message
    if ( !$options_okay ) {
        pod2usage( -exitval => 2, -verbose => $SHOW_USAGE_ONLY );
    }

    if ( $options->{'help'} ) {
        pod2usage( -exitval => 0, -verbose => $SHOW_BRIEF_HELP_MESSAGE );
    }

    if ( $options->{'man'} ) {
        pod2usage( -exitval => 0, -verbose => $SHOW_FULL_MANUAL );
    }

    # Check required options
    foreach my $option (qw(repository config)) {
        if ( !$options->{$option} ) {
            pod2usage(
                -message => "Option $option is required",
                -exitval => 2,
                -verbose => $SHOW_USAGE_ONLY,
            );
        }
    }

    # Either transaction or revision ID should be set but not the both
    if ( $options->{'transaction'} && $options->{'revision'} ) {
        pod2usage(
            -message =>
                'You cannot set the both transaction and revision IDs',
            -exitval => 2,
            -verbose => $SHOW_USAGE_ONLY,
        );
    }

    if ( !$options->{'transaction'} && !$options->{'revision'} ) {
        pod2usage(
            -message => 'You should set either transaction or revision ID',
            -exitval => 2,
            -verbose => $SHOW_USAGE_ONLY,
        );
    }

    ### options: $options
    return $options;
}

#-------------------------------------------------------------------------------
#  Load and parse configuration file
#-------------------------------------------------------------------------------
sub get_config {
    my $file_name = shift;

    # Slurp and eval Perl-code from $file_name
    my $config = do $file_name;

    if ( !$config ) {

        # Cannot parse
        if ($EVAL_ERROR) {
            die "Cannot parse $file_name: $EVAL_ERROR\n";
        }

        # File not found or not accessible
        if ( !defined $config ) {
            die "Cannot read $file_name: $OS_ERROR\n";
        }

        # Last expression in $file_name was evaluated as false
        if ( !$config ) {
            die "Bad file format: $file_name\n";
        }
    }

    # Check that we've got an HASH ref
    if ( ref $config ne 'HASH' ) {
        die "Bad file format: $file_name - HASH ref was expected\n";
    }

    ### config: $config
    return $config;
}

#-------------------------------------------------------------------------------
#  Search for svnlook binary in some standard places
#-------------------------------------------------------------------------------
sub find_svnlook_binary {
    my $root        = rootdir();
    my @search_list = ();

    push @search_list, path();
    push @search_list, catfile( $root, 'usr', 'local', 'bin' );
    push @search_list, catfile( $root, 'usr', 'bin' );
    push @search_list, catfile( $root, 'bin' );

    foreach my $dir (@search_list) {
        my $file = catfile( $dir, 'svnlook' );
        return $file if -x $file;
    }

    die "Cannot find svnlook binary\n";
}

#-------------------------------------------------------------------------------
#  Create SVN::Look object to query information about this commit
#-------------------------------------------------------------------------------
sub create_svnlook_for_this_commit {

    my $txn_id = $Options->{'transaction'};
    my $rev_id = $Options->{'revision'};

    # Decide what to use: either transaction or revision ID
    my $query_by = $txn_id ? '-t'    : '-r';
    my $id       = $txn_id ? $txn_id : $rev_id;

    # SVN::Look searches for the svnlook binary in $PATH,
    # /usr/local/bin, /usr/bin and finally /bin. Also keep
    # in mind that the hook program typically does not inherit
    # the environment of its parent process. So, if your
    # svnlook binary lives in some non-standard place, export
    # $PATH variable somewhere in your pre-commit script explicitly.
    my $svnlook = SVN::Look->new( $Options->{'repository'}, $query_by, $id );

    croak 'Cannot create SVN::Look object' if !$svnlook;

    return $svnlook;
}

#-------------------------------------------------------------------------------
#  Create SVN::Look object to query information about previous commit.
#  This information is required in progressive mode to compare file
#  content in current commit and previous one.
#-------------------------------------------------------------------------------
sub create_svnlook_for_prev_commit {

    # At the moment of writing SVN::Look lacks youngest() method,
    # that's why I have to run appropriate shell command manually.
    my $svnlook_binary = find_svnlook_binary();
    my $repository     = $Options->{'repository'};

    ## no critic (ProhibitBacktickOperators)
    my $youngest_rev_id = qx{$svnlook_binary youngest '$repository'};

    if ( $CHILD_ERROR != 0 ) {
        croak 'Cannot get youngest revision ID';
    }

    chomp $youngest_rev_id;
    my $svnlook = SVN::Look->new( $repository, '-r', $youngest_rev_id );

    croak 'Cannot create SVN::Look object' if !$svnlook;

    return $svnlook;
}

#-------------------------------------------------------------------------------
#  Is this commit emergent?
#-------------------------------------------------------------------------------
sub is_emergency_commit {
    my $this_commit = shift;

    if ( $Config->{'allow_emergency_commits'} ne $YES ) {
        return $NO;
    }

    my $quoted_prefix = quotemeta $Config->{'emergency_comment_prefix'};
    ## no critic (RequireExtendedFormatting)
    if ( $this_commit->log_msg() =~ /\A$quoted_prefix/ms ) {
        ### emergency commit requested...
        ### log_msg: $this_commit->log_msg()
        ### magic prefix: $Config->{'emergency_comment_prefix'}
        return $YES;
    }
    else {
        return $NO;
    }
}

#-------------------------------------------------------------------------------
#  Find perlcritic's profile for the file. Relative paths will be mapped
#  under $REPOS/hooks/perlcritic.d/ directory
#-------------------------------------------------------------------------------
sub get_profile_for {
    my $file = shift;

    my $profiles = $Config->{'profiles'};

    my $last_match = last_value { $file =~ $_->{'pattern'} } @{$profiles};
    return if !defined $last_match;

    my $profile = $last_match->{'profile'};

    if ( !file_name_is_absolute($profile) ) {
        ### relative profile path: $profile
        $profile = catfile( $Options->{'repository'},
            'hooks', 'perlcritic.d', $profile );
        ### absolute profile path: $profile
    }

    return $profile;
}

#-------------------------------------------------------------------------------
#  Colorize string using specified color
#-------------------------------------------------------------------------------
sub colorize {
    my $string = shift;
    my $color  = shift;

    return Term::ANSIColor::colored( $string, $color );
}

#-------------------------------------------------------------------------------
#  Sort violations by severity level (most severe - first), policy name, line
#  number and finally column number. Due to lack of logical_line_number() and
#  column_number() methods in Perl::Critic v1.088 which comes with Debain Lenny
#  I have to use (potentially) less portable method location().
#-------------------------------------------------------------------------------
sub sort_by_severity_policy_line_col {    ## no critic (RequireArgUnpacking)
    ## no critic (ProhibitMagicNumbers, ProhibitReverseSortBlock)
    # Schwartzian transform
    return map { $_->[0] } sort {
               ( $b->[1] <=> $a->[1] )
            || ( $a->[2] cmp $b->[2] )
            || ( $a->[3] <=> $b->[3] )
            || ( $a->[4] <=> $b->[4] )
        } map {
        [   $_,
            $_->severity()      || 0,            # 1..5, most severe - 5
            $_->policy()        || $EMPTY_STR,
            $_->location()->[0] || 0,            # line number
            $_->location()->[1] || 0             # column number
        ]
        } @_;
}

#-------------------------------------------------------------------------------
#  Sort violations emitted in progressive mode by severity (most severe - first)
#  minimal number of required fixes (most violations rich - first) and
#  finally policy name.
#-------------------------------------------------------------------------------
sub sort_by_severity_min_fixes_policy {
    my $min_fixes_of = shift;
    my $severity_of  = shift;

    my @violations = keys %{$min_fixes_of};
    my @sorted_violations = sort {    ## no critic (ProhibitReverseSortBlock)
        ( $severity_of->{$b} <=> $severity_of->{$a} )
            || ( $min_fixes_of->{$a} <=> $min_fixes_of->{$b}
            || ( $a cmp $b ) )
    } @violations;

    return @sorted_violations;
}

#-------------------------------------------------------------------------------
#  Build an auxiliary hash table with a counter for each type of violation
#-------------------------------------------------------------------------------
sub get_violations_count_per_policy {
    my $violations_aref = shift;

    my $violations_count_href = {};

    foreach my $violation ( @{$violations_aref} ) {
        $violations_count_href->{ $violation->policy() } ||= 0;
        $violations_count_href->{ $violation->policy() }++;
    }

    return $violations_count_href;
}

#-------------------------------------------------------------------------------
#  Count how many *new* violations of each type were introduced in this commit
#-------------------------------------------------------------------------------
sub get_min_number_of_required_fixes_per_policy {
    my $violations_count_before_href = shift;
    my $violations_count_now_href    = shift;

    my $min_fixes_required_href = {};
    foreach my $policy ( keys %{$violations_count_now_href} ) {
        my $now = $violations_count_now_href->{$policy};
        my $before = $violations_count_before_href->{$policy} || 0;

        if ( $now > $before ) {
            $min_fixes_required_href->{$policy} = $now - $before;
        }
    }

    return $min_fixes_required_href;
}

#-------------------------------------------------------------------------------
#  Format violations according to the specified verbosity value,
#  sort them (by severity level, policy name, line and column
#  numbers) and colorize them by severity level if requested.
#-------------------------------------------------------------------------------
sub format_violations {
    my $violations = shift;
    my $perlcritic = shift;
    my $file       = shift;

    # Get verbosity level (from perlcritic's profile!)
    my $verbosity = $perlcritic->config->verbose();

    # Set format string according to `versbose' parameter
    my $fmt = Perl::Critic::Utils::verbosity_to_format($verbosity);

    # Prepend %f (placeholder for file name) if not specified
    if ( $fmt !~ /%f/xms ) {
        $fmt = "%f: $fmt";
    }

    # Replace %f and %F with actual file name (%f and %F are
    # undefined when the code to critique comes from the string).
    $fmt =~ s{\%[fF]}{$file}xms;

    Perl::Critic::Violation::set_format($fmt);

    # Do we need to colorize violations by severity level?
    my $is_color_requested = $perlcritic->config->color();

    # Severity-to-color mapping (constants from Perl::Critic::Utils)
    Readonly my %COLOR_OF => (
        $SEVERITY_HIGHEST => 'red',        # brutal
        $SEVERITY_HIGH    => 'yellow',     # cruel
        $SEVERITY_MEDIUM  => 'magenta',    # harsh
        $SEVERITY_LOW     => 'cyan',       # stern
        $SEVERITY_LOWEST  => 'green',      # gentle
    );

    my @sorted_violations
        = sort_by_severity_policy_line_col( @{$violations} );

    # Stringify and colorize (if requested) violations
    my @formatted_violations = ();
    if ($is_color_requested) {
        @formatted_violations
            = map { colorize( $_->to_string(), $COLOR_OF{ $_->severity() } ) }
            @sorted_violations;
    }
    else {
        @formatted_violations = map { $_->to_string() } @sorted_violations;
    }

    # Trim long list of violations if requested
    if ( my $max_violations = $Config->{'max_violations'} ) {
        my $violation_count = @formatted_violations;
        if ( $violation_count > $max_violations ) {
            $#formatted_violations = $max_violations - 1;    # trim array
            my $warning_msg
                = "Only $max_violations/$violation_count most severe violations are shown";

            push @formatted_violations, $warning_msg . qq{\n};
        }
    }

    return join q{}, @formatted_violations;
}

#-------------------------------------------------------------------------------
#  Format violations emitted in progressive mode. Return value consists of two
#  parts: report generated using format_violations() function plus "progressive"
#  report. The later shows now many new violations of each type were introduced
#  in this commit comparing to the previous one.
#-------------------------------------------------------------------------------
sub format_violations_progressively {
    my $violations_before_aref = shift;
    my $violations_now_aref    = shift;
    my $perlcritic             = shift;
    my $file                   = shift;

    my $violations_count_before_href
        = get_violations_count_per_policy($violations_before_aref);
    ### violations_count_before_href: $violations_count_before_href

    my $violations_count_now_href
        = get_violations_count_per_policy($violations_now_aref);
    ### violations_count_now_href: $violations_count_now_href

    # build policy_name-to-severity lookup table
    my %severity_of
        = map { ( $_->policy(), $_->severity() ) } @{$violations_now_aref};
    ### severity_of: %severity_of

    my $min_fixes_required_href = get_min_number_of_required_fixes_per_policy(
        $violations_count_before_href, $violations_count_now_href );
    ### min_fixes_required_href: $min_fixes_required_href

    # No new violations have been introduced? Cool!
    return $EMPTY_STR if scalar keys %{$min_fixes_required_href} == 0;

    my @sorted_policies
        = sort_by_severity_min_fixes_policy( $min_fixes_required_href,
        \%severity_of );
    ### sorted_policies: @sorted_policies

    my $max_violations  = $Config->{'max_violations'};
    my $violation_count = @{$violations_now_aref};

    # The first part of report
    my $formatted_violations;
    if ( $max_violations && $violation_count > $max_violations ) {
        $formatted_violations
            = "$file: Too many violations ($violation_count). "
            . 'Please run perlcritic locally, e.g.: '
            . "perlcritic --single-policy PolicyNameFromBelow FooBar.pm\n";
    }
    else {
        $formatted_violations
            = format_violations( $violations_now_aref, $perlcritic, $file );
    }

    my $is_color_requested = $perlcritic->config->color();

    # The second part of report
    foreach my $policy (@sorted_policies) {
        my $short_policy = $policy;
        $short_policy =~ s/^Perl::Critic::Policy:://xms;

        my $severity = $severity_of{$policy};

        my $was = $violations_count_before_href->{$policy} || 0;
        my $now = $violations_count_now_href->{$policy};
        my $min = $min_fixes_required_href->{$policy};

        my $report_line
            = "$file: [$short_policy] You should fix at least $min violation(s) "
            . "of this type (was: $was, now: $now) (Severity: $severity)";

        if ($is_color_requested) {
            $formatted_violations
                .= colorize( $report_line, 'blue on_white' ) . qq{\n};
        }
        else {
            $formatted_violations .= $report_line . qq{\n};
        }
    }

    return $formatted_violations;
}

#-------------------------------------------------------------------------------
#  Critique a single file
#-------------------------------------------------------------------------------
sub critique_file {
    my $this_commit = shift;
    my $file        = shift;
    my $profile     = shift;

    my $perlcritic   = Perl::Critic->new( -profile => $profile );
    my $file_content = $this_commit->cat($file);
    my @violations   = $perlcritic->critique( \$file_content );

    my $formatted_violations
        = format_violations( \@violations, $perlcritic, $file );

    return $formatted_violations;
}

#-------------------------------------------------------------------------------
#  Critique a single file in progressive mode, i.e. don't complain abount
#  existing violations but prevent intruducing new ones.
#-------------------------------------------------------------------------------
sub critique_file_progressively {
    my $this_commit = shift;
    my $prev_commit = shift;
    my $file        = shift;
    my $profile     = shift;

    my $perlcritic = Perl::Critic->new( -profile => $profile );

    my $file_content_before = $prev_commit->cat($file);
    my @violations_before   = $perlcritic->critique( \$file_content_before );

    my $file_content_now = $this_commit->cat($file);
    my @violations_now   = $perlcritic->critique( \$file_content_now );

    my $formatted_violations
        = format_violations_progressively( \@violations_before,
        \@violations_now, $perlcritic, $file );

    return $formatted_violations;
}

#-------------------------------------------------------------------------------
#  Process list of files using Perl::Critic
#-------------------------------------------------------------------------------
sub critique_files {
    my $this_commit            = shift;
    my $prev_commit            = shift;
    my $files_aref             = shift;
    my $critique_progressively = shift;

    my $violations = $EMPTY_STR;

FILE:
    foreach my $file ( @{$files_aref} ) {
        my $profile = get_profile_for($file);
        next FILE if !defined $profile;

        ### processing file: $file
        ### profile: $profile

        if ( $critique_progressively eq $YES ) {
            $violations
                .= critique_file_progressively( $this_commit, $prev_commit,
                $file, $profile );
        }
        else {
            $violations .= critique_file( $this_commit, $file, $profile );
        }
    }

    return $violations;
}

#-------------------------------------------------------------------------------
#  Collect violations from all files
#-------------------------------------------------------------------------------
sub get_violations {
    my $this_commit = shift;
    my $prev_commit = shift;

    # sort() is not required but it makes tests more robust
    my @added_files   = sort grep { $_ !~ m{/$}xms } $this_commit->added();
    my @updated_files = sort grep { $_ !~ m{/$}xms } $this_commit->updated();

    ### added files: @added_files
    ### updated files: @updated_files

    my $violations = $EMPTY_STR;

    # Always critique ADDED files strictly
    $violations
        .= critique_files( $this_commit, $prev_commit, \@added_files, $NO );

    # Critique UPDATED files progressively only if it is requested,
    # use strict mode otherwise.
    $violations
        .= critique_files( $this_commit, $prev_commit, \@updated_files,
        $Config->{'progressive_mode'} );

    return $violations;
}

#-------------------------------------------------------------------------------
#  Report violations with some additional hints
#-------------------------------------------------------------------------------
sub report_violations {
    my $violations = shift;

    ## no critic (RequireCheckedSyscalls)
    print {*STDERR} $violations;

    if ( $Config->{'allow_emergency_commits'} eq $YES ) {
        my $prefix = $Config->{'emergency_comment_prefix'};
        print {*STDERR} <<"END_HINT"
---
You can bypass all checks by placing '$prefix' in the begining of the comment message,
e.g.: svn ci -m "$prefix: emergency hotfix" FooBar.pm
END_HINT
    }

    return;
}

#-------------------------------------------------------------------------------
#  Entry point
#-------------------------------------------------------------------------------
sub main {
    $Options = get_options();
    $Config  = get_config( $Options->{'config'} );

    my $this_commit = create_svnlook_for_this_commit();
    my $prev_commit = create_svnlook_for_prev_commit();

    if ( is_emergency_commit($this_commit) eq $YES ) {
        exit $ALLOW_COMMIT;
    }

    my $violations = get_violations( $this_commit, $prev_commit );

    if ( $violations eq $EMPTY_STR ) {
        exit $ALLOW_COMMIT;
    }
    else {
        report_violations($violations);
        exit $DENY_COMMIT;
    }

    return;
}

main();

__END__

=head1 NAME

perlcritic-checker.pl - Tool for automating code quality control

=head1 SYNOPSIS

perlcritic-checker.pl [options]

 Options:
   --revision|-r       Revision ID
   --transaction|-t    Transaction ID
   --repository|-p     Path to SVN repository
   --config|-c         Path to config file
   --help|-?           Show brief help message
   --man               Show full documentation
 

=head1 USAGE EXAMPLE

Put this into your Subversion's pre-commit hook:

/abs/path/to/perlcritic-checker.pl -p $REPOS -c /abs/path/to/perlcritic-checker.conf -t $TXN || exit 1

=head1 DESCRIPTION

perlcritic-checker is a subversion hook that allows commits to go through
if and only if the code passes validation using Perl::Critic module.
This way you can apply consistent coding practices inside your team.

Main features:

=over 4

=item * you can specify different Perl::Critic's profiles for different
paths in your repository

=item * you can bypass checks when you do need this

=item * you can apply the checker to your existing large legacy Perl
project by using "progressive mode" feature: in progressive mode
perlcritic-checker doesn't complain about existing violations but prevents
introducing new ones

=item * perlcritic-checker comes with a test suite

=back

=head1 CONFIGURATION FILE

Configuration file example follows. In fact, it's a ordinary Perl hash.
You can check it using `perl -c' to avoid syntax errors.

 {
     # Progressive mode: {0|1}. In progressive mode perlcritic-checker
     # doesn't complains about existing violations but prevents
     # introducing new ones. Nice feature for applying Perl::Critic
     # to the existing projects gradually.
     progressive_mode => 1,
 
     # Emergency commits: {0|1}. There are situations when you *do* need
     # to commit changes bypassing all checks (e.g. emergency bug fixes).
     # This featue allows you bypass Perl::Critic using "magic" prefix in
     # comment message, e.g.: svn ci -m "NO CRITIC: I am in hurry" FooBar.pm
     allow_emergency_commits  => 1,
 
     # Magic prefix described above can be customized:
     emergency_comment_prefix => 'NO CRITIC',

     # Limit maximal number of reported violations. This parameter works
     # differently in strict and progressive modes. In strict mode it
     # will truncate long list of violations: only N most severe violations
     # will be shown. In progressive mode such behaviour has no sense,
     # that's why user will be asked to run perlcritic locally.
     #
     # In fact, this parameter is a workaround for a subtle bug in generic
     # svn-client that happens when svn hook (i.e. perlcritic-checker.pl)
     # outputs too much data: svn-client just reports "Connection closed
     # unexpectedly". In order to reproduce this bug several additional
     # conditions should be met:
     # - repository access scheme: 'svn://' (svnserve daemon)
     # - client and server on different machines
     # - svn-client and -server are running on linux
     # 
     # If you face the same problem, try to use the option below.
     #max_violations => 50,
 
     # SVN repository path -- to -- Perl::Critic's profile mapping.
     #
     # This feature allows you to apply different Perl::Critic's
     # policies for different paths in the repository. For example,
     # you can be very strict with brand-new projects, make an
     # indulgence for some existing project and completely disable
     # checking of auto-generated or third-party code.
     #
     # Each modified (added, updated, copied, moved) file name in the
     # repository is matched against a sequence of patterns below.
     # Keep in mind, *last* matching rule - wins.
     #
     # Profile paths can be either absolute or relative. In the later
     # case they will be mapped under $REPOS/hooks/perlcritic.d directory.
     profiles => [
         # Apply default profile for all Perl-code under 'project_name/trunk'
         {
             pattern => qr{project_name/trunk/.*?[.](pm|pl|t)$},
             profile => 'default-profile.conf',
         },
 
         # Disable checking of autogenerated Perl-code
         {
             pattern => qr{autogenerated-script[.]pl$},
             profile => undef,
         },
     ],
 }

Format of Perl::Critic's profiles is described in perlcritic(1p).
Here is an example:

 # Make perlcritic very exacting
 severity = brutal
 
 # You can choose any level from 1 to 11, but 8 is recommended
 verbose = 8
 
 # Colorize violations depending on their severity level
 color = 1
 
 # Halt if this file contains errors
 profile-strictness = fatal
 
 # Ask perlcritic for a little indulgence
 exclude = Documentation
 
 # Explicitly set full path to Perl::Tidy's config
 [CodeLayout::RequireTidyCode]
 perltidyrc = /etc/perltidyrc

=head1 EXIT STATUS

0 - No code violations found, allow commit

1 - Code violations have been found, deny commit

255 - Error has occured, deny commit


=head1 SEE ALSO

http://perlcritic.com

=head1 AUTHOR

Alexander Simakov, <xdr (dot) box (at) Google Mail>

http://alexander-simakov.blogspot.com/

http://code.google.com/p/perlcritic-checker

=head1 LICENSE AND COPYRIGHT

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

=cut
