# -*- perl -*-
#


use Test::More;
use File::Temp	'tmpnam';

umask 077;

my ($script_fh, $script_path) = tmpnam;
my $output_path               = tmpnam;

printf $script_fh <<'-', $^X, $output_path, $output_path;
#!%s -Tw -Iblib/lib

use CGI::Alert		qw(nobody http_die);
use CGI;

# Not interested in any email being sent
$SIG{__DIE__}  = 'DEFAULT';
$SIG{__WARN__} = sub { print STDOUT @_ };

open STDOUT, '>', '%s'
  or die "Cannot create %s: $!\n";

CGI::Alert::extra_html_headers(
		-author  => 'esm@pobox.com',
                -head    => CGI::Link({-rel  => 'shortcut icon',
                                  -href => '/foo.ico',
                                  -type => 'image/x-icon',
                                 }),
		-style   => {
			     -src  => '/foo.css',
			    },
	       );


# Here we go.
http_die '400 Bad Request', 'this is the body';
-


close $script_fh;

chmod 0500 => $script_path;

my @expect = <DATA>;

plan tests => 1 + @expect;

{
    local %ENV =
      (
       (map { $_ => $ENV{$_} || 'undef' } qw(HOME PATH LOGNAME USER SHELL)),

       HTTP_HOST      => 'http-host-name',
       REQUEST_URI    => '/sample/url',
      );

    system $script_path;
}

is $?, 0, 'exit code of sample script';

my $i = 0;
open ERROR, '<', $output_path;
while (@expect && defined (my $line = <ERROR>)) {
    chomp $line;
    $line =~ tr/\r//d;		# Get rid of DOS ^Ms
    $line =~ s!\S+(/CGI/Alert\.pm line )\d+!.*$1XX!;

    # What we expect to see, (from below).
    my $expect = shift @expect;
    chomp $expect;
#    $expect =~ s/\s+/\\s+/g;		# Ignore whitespace diffs

    # Generate a description of this test
    my $desc = "output line " . ++$i;

    like $line, qr/^$expect$/, $desc;
}
close ERROR;

unlink $script_path, $output_path;



__END__
Status: 400 Bad Request
Content-Type: text/html; charset=ISO-8859-1

<\?xml version="1.0" encoding="iso-8859-1"\?>
<!DOCTYPE html
	PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
	 "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml".*><head><title>400 Bad Request</title>
<link rev="made" href="mailto:esm%40pobox.com" />
<link type="image/x-icon" rel="shortcut icon" href="/foo.ico" />
<link rel="stylesheet" type="text/css" href="/foo.css" />
</head><body>

<h1>Bad Request</h1>
<p />
this is the body
<p />
<hr />
Script error: 400 Bad Request
: this is the body at .*/CGI/Alert.pm line XX.
