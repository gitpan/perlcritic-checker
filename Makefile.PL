#!/usr/bin/perl

use strict;
use warnings;

use ExtUtils::MakeMaker;

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
