#!/usr/bin/perl

#===============================================================================
#     REVISION:  $Id: diff-ecpected-got.pl 57 2011-02-25 22:37:35Z xdr.box $
#  DESCRIPTION:  Handy tool for maintaining test suite
#===============================================================================

use strict;
use warnings;

our $VERSION = qw($Revision: 57 $) [1];

use Readonly;
use English qw( -no_match_vars );
use File::Temp qw( tempfile tempdir );

sub main {

    # Note: '' quotes
    my $got = <<'END_GOT';
END_GOT

    # Note: "" quotes
    my $expected = <<"END_EXPECTED";
END_EXPECTED

    my ( $got_fh, $got_filename ) = tempfile();
    print {$got_fh} $got;

    my ( $expected_fh, $expected_filename ) = tempfile();
    print {$expected_fh} $expected;

    system "colordiff -Naur $expected_filename $got_filename";

    return;
}

main();
