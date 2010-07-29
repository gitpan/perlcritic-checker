#!/usr/bin/perl

use strict;
use warnings;

use ExtUtils::MakeMaker;
use File::Spec::Functions qw(catfile path);

if ( !has_subversion() ) {
    print "Subversion is not installed\n";
    exit 0;
}

WriteMakefile(
    NAME         => 'perlcritic-checker',
    AUTHOR       => 'Alexander Simakov <xdr (dot) box (at) Google Mail>',
    ABSTRACT     => 'Perl::Critic Subversion Hook',
    VERSION_FROM => 'bin/perlcritic-checker.pl',
    LICENSE      => 'gpl',
    EXE_FILES    => ['bin/perlcritic-checker.pl'],
    PL_FILES     => {},
    PREREQ_PM    => {
        'Readonly'              => 0,
        'Pod::Usage'            => 0,
        'SVN::Look'             => 0,
        'Perl::Critic'          => 0,
        'Term::ANSIColor'       => 0,
        'File::Copy::Recursive' => 0,
        'Test::Command'         => 0,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES    => 'perlcritic-checker-*' },
);

sub has_subversion {
CMD:
    for my $cmd (qw{svn svnadmin svnlook}) {
        for my $path ( path() ) {
            next CMD if -x catfile( $path, $cmd );
        }
        return 0;
    }

    return 1;
}
