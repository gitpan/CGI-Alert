# -*- perl -*-
#
# CGI::Alert.pm  -  notify a human about errors/warnings in CGI scripts
#
# $Id: Alert.pm,v 1.21 2003/11/07 21:24:06 esm Exp $
#
package CGI::Alert;

use strict;
use warnings;
use Carp;

###############################################################################
# BEGIN user-configurable section

# If set (by caller, via emit_http_headers), emit HTTP headers
our $Emit_HTTP_Headers = 0;

# By default, send notifications to this address.  We could try to be
# clever about stat'ing the calling script and finding the owner, but
# why go to so much effort?
our $Maintainer = 'webmaster';

# Expressions to filter from the email.  We don't want to send passwords,
# credit card numbers, or other sensitive info out via email.
our @Hide = (qr/[\b_-]passw/i);

# For stack trace: names of the fields returned by caller(), in order.
our @Caller_Fields =
  qw(
     package
     filename
     line
     subroutine
     hasargs
     wantarray
     evaltext
     is_require
     hints
     bitmask
    );

#
# Package globals, checked at END time.
#
our @cgi_params;		# CGI inputs (GET/POST), set at INIT time

my @warnings;			# Warnings, both plain...
my @warnings_traced;		#                     ...and with stack trace.

# For debugging this module, and running tests.  Set by t/*.t to a
# file path.  We write our email to this file, instead of running sendmail.
our $DEBUG_SENDMAIL = '';

# END   user-configurable section
###############################################################################

# Program name of our caller
our $ME = $ENV{REQUEST_URI} || $0 || "<???>";

# RCS ID, on one line for MakeMaker
our $VERSION = '1.02';

############
#  import  #  If called with "use CGI::Alert 'foo@bar'", send mail to foo@bar
############
sub import {
    my $i = 1;
    while ($i < @_) {
	# Is it a valid exported function?  Skip.
	if (exists &{$_[$i]}) {
	    $i++
	}
	elsif ($_[$i] =~ m!^-{0,2}hide=(.+)$!) {	# RE to filter out?
	    my $hide = $1;		# Our input
	    my $re;			# ...how we interpret it
	    if    ($hide =~ m!^/(.*)/$!)		{ $re= "qr/$1/"      }
	    elsif ($hide =~ m!^m(.)(.*)\1$!)		{ $re= "qr/$2/"      }
	    elsif ($hide =~ m!^(qr(.)(.*)\2[ismx]*)$!)	{ $re= $1	      }
	    else					{ $re= "qr/$hide/" }

	    # Make sure it can be parsed as a regex.
	    my $result = eval $re;
	    if ($@) {
		carp "Ignoring invalid filter expression '$re': $@";
	    }
	    else {
		push @Hide, $result;
	    }

	    # Eliminate it from our import list
	    splice @_, $i, 1;
	}
	else {
	    # Anything else: must be an email address.  Point $Mainainer at it,
	    # and remove from our arg list so Exporter doesn't see it.
	    ($Maintainer) = splice @_, $i, 1;
	    # (don't increment $i, since we've collapsed the array)
	}
    }

    # If we ever become an Exporter, un-comment this out
#    CGI::Alert->export_to_level(1, @_);
}

##################
# Final override.  This is run after the import, and thus has the last
# say on who gets notified.
#
# We examine our URL.  If it's of the form "/~user/something", assume
# that "user" is debugging, and would prefer that notifications go just
# to him/her.
##################
INIT {
    # Invoked from user URL (~user/...) ?  Debugging -- send mail to him/her
    if (($ENV{REQUEST_URI} || "") =~ m!/(~|%7e)([^/]+)/!i) {
	$Maintainer = $2;
    }

    # If called with CGI parameters, remember them now.  Otherwise, our
    # caller could call Delete_all() (from CGI.pm) or otherwise clear
    # the params, so we wouldn't have them when our END handler is called.
    if (exists $INC{'CGI.pm'}) {
	eval {
	    # Each element of @cgi_params is an array ref: first element is
	    # the param name, everything else is one or more values.
	    foreach my $p (CGI::param()) {
		push @cgi_params, [ $p, CGI::param($p) ];
	    }
	};
	print STDERR __PACKAGE__, ": error in eval: $@\n"		if $@;
    }
}

###############################################################################
# BEGIN helper functions

###############
#  _basename  #  Poor man's implementation, to avoid including File::Basename
###############
sub _basename($) {
    my $f = shift;

    $f =~ m!/([^/]+)$!
      and return $1;
    return $f;
}

##################
#  _stack_trace  #  returns pretty stack trace
##################
sub _stack_trace() {
    my @levels;

    # Get a full callback history, first-is-first (that is, the
    # main script is first, instead of the usual most-recent-first).
    # @levels will be a LoH, an array containing hashrefs.
    #
    # See perlfunc(1) for details on caller() and the 'DB' hack.
    my $i = 0;
    my @call_info;
    while (do { { package DB; @call_info = caller($i++) } } ) {
	unshift @levels, {
			  (map { $_ => shift @call_info } @Caller_Fields),
			  args => [ @DB::args ],
			 };
    }

    # The last few levels of subroutine calls are all inside this
    # module.  Exclude them.
    while ($levels[-1]->{filename} =~ m!/Alert\.pm$!) {
	pop @levels;
    }

    # Last function in the trace is the one that invoked warn/die.
    # Instead of showing our local sub name, show 'warn' or 'die'.
    if ($levels[$#levels]->{subroutine} =~ /^CGI::Alert::_(warn|die)$/) {
	$levels[$#levels]->{subroutine} = $1;
    }

    # Determine the length of the longest filename
    my $maxlen = -1;
    for my $lev (@levels) {
	my $len = length( _basename($lev->{filename}) );
	$maxlen < $len
	  and $maxlen = $len;
    }

    my $retval = '';			# Returned string.
    my $indent = "  ";			# Function indentation level
    my $last_filename = '';		# Last filename seen

    for my $l (@levels) {
	my $filename = _basename($l->{filename});

	# Same as last file seen?  Don't bother to display it.
	if ($filename eq $last_filename) {
	    $filename =~ s|.| |g;
	}
	else {
	    $last_filename = $filename;		# remember for next time
	}

	# Filename, line number, and subroutine name.
	$retval .= sprintf("  %-*s : %4d  %s%s(", $maxlen, $filename,
			   $l->{line},
			   $indent, $l->{subroutine});

	# Function arguments, in parenthesized list.
	my $comma = '';
	for my $arg (@{$l->{args}}) {
	    # Perform minor adjustments on each arg
	    if (!defined $arg) {
		$arg = 'undef';
	    }
	    elsif (!ref $arg) {  # not a ref: must be a string, or a number
		$arg =~ s|\n|\\n|g;	# escape newlines
		$arg =~ /\D/		# quote strings
		  and $arg = "\"$arg\"";
	    }
	    $retval .= "$comma $arg";
	    $comma = ',';
	}
	$retval .= " )\n";

	# Keep indenting each subsequent level in the stack trace.
	$indent .= "  ";
    }

    $retval;
}


################
#  maintainer  #  returns nicely formatted HREF and address of maintainer
################
sub maintainer() {
    my $real_name = "";
    my $just_mail = $Maintainer;

    # Address is of the form "Foo Bar <fubar@some.where>" ?
    if ($just_mail =~ /\s*<(.*)>\s*/) {
	$real_name = "<b>$`$'</b> ";
	$just_mail = $1;
    }
    $real_name =~ s|\s+|&nbsp;|g;

    return "maintainer,&nbsp;$real_name&lt;<a href=\"mailto:$Maintainer\"><samp>$just_mail</samp></a>&gt;";
}

# END   helper functions
###############################################################################
# BEGIN main notification function

############
#  notify  #  Gets called on END, to send email to maintainer
############
sub notify($@) {
    my $subject = shift;

    eval {
	my %env = %ENV;
	local %ENV;
	local $ENV{PATH} = "/usr/sbin:/usr/lib";	# Where sendmail lives

	# MIME part divider
	my $b = sprintf("==XxX%05d", $$);

	my $sendmail = ($DEBUG_SENDMAIL
			? "> $DEBUG_SENDMAIL"
			: '| sendmail -oi -t');

	open(SENDMAIL, $sendmail)
	  or do {
	      print STDERR "Could not fork sendmail: $!\n";
	      exit 1;
	  };

	my $http_host   = $env{HTTP_HOST}   || "localhost";
	my $request_uri = $env{REQUEST_URI} || "/unknown-url";

	my $package = __PACKAGE__;	# Can't string-interpolate __PACKAGE__

	# Do we know the remote user? Make it easy for maintainer to reply.
	exists $env{REMOTE_USER} && $env{REMOTE_USER}
	  and print SENDMAIL "Reply-To: $env{REMOTE_USER}\n";

	# Include CGI script name and version (if known) in X-mailer
	my $cgi_script = _basename($0);
	$cgi_script .= " v$main::VERSION"	if defined $main::VERSION;

	print  SENDMAIL <<"-";
From:    CGI Alert <nobody>
To:      $Maintainer
Subject: $subject in http://$http_host$request_uri
X-mailer: $cgi_script, via $package v$VERSION
Precedence: bulk
MIME-Version: 1.0
Content-Type: multipart/mixed;
	boundary="$b"

This is a MIME-Encapsulated message.  You can read it as plain text
if you insist.

--$b
Content-Type: text/plain; charset=us-ascii

-

	# Message body: start with whatever the user told us to say.
	print  SENDMAIL $_, "\n"			foreach @_;
	print  SENDMAIL "\n";

	# Display remote user/host info
	if (exists $env{REMOTE_USER} || exists $env{REMOTE_ADDR}) {
	    print  SENDMAIL "Remote user is ";

	    if (exists $env{REMOTE_USER}) {
		print  SENDMAIL $env{REMOTE_USER} || "<unknown>";
		print  SENDMAIL  " @ "	if exists $env{REMOTE_ADDR};
	    }
	    if (exists $env{REMOTE_ADDR}) {
		# Find out remote host name.  Bracket inside an EVAL, so we
		# don't slow down normal execution by doing "use Socket".
		my @a = eval 'use Socket qw(AF_INET inet_aton);
                        gethostbyaddr(inet_aton($env{REMOTE_ADDR}), AF_INET);';
		if ($@) {
		    print  SENDMAIL $env{REMOTE_ADDR};
		} else {
		    printf SENDMAIL "%s [%s]", $a[0]||"<??>",$env{REMOTE_ADDR};
		}
	    }
	    print  SENDMAIL "\n";
	}

	# Display our name and version
	print  SENDMAIL "\n",
	                "This message brought to you by $package v$VERSION\n";


	# If this was a "die", add a stack trace
	$subject =~ /FATAL/ and eval {
	    local $SIG{__DIE__};
	    print  SENDMAIL <<"-", _stack_trace;

--$b
Content-Type: text/plain; name="stack-trace"
Content-Description: Stack Trace

-
	};

	#
	# If CGI.pm is loaded, and we had CGI params, make a new MIME section
	# showing each param and its value(s).  This is all wrapped in an
	# eval block, since we don't want to call CGI::param() if CGI.pm
	# isn't loaded (plus, we don't really care about errors).
	#
	@cgi_params and eval {
	    local $SIG{__DIE__};

	    # MIME boundary.  Describe the new section, and show GET or POST
	    my $method = $env{REQUEST_METHOD} || "no REQUEST_METHOD";
	    print  SENDMAIL <<"-";

--$b
Content-Type: text/plain; name="CGI-Params"
Content-Description: CGI Parameters ($method)

-

	    # Find length of longest param...
	    my $maxlen = -1;
	    foreach my $set (@cgi_params) {
		$maxlen < length($set->[0])
		  and $maxlen = length($set->[0]);
	    }
	    # ...then display each, one per line
	    foreach my $set (@cgi_params) {
		my ($p, @v) = @$set;

		# For security purposes, never send out passwords, credit cards
		grep { $p =~ /$_/ } @Hide
		  and @v = ('[...]');

		printf SENDMAIL "  %-*s = %s\n", $maxlen, $p, $v[0] || "";
		# If this param is an array of more than one value, show all.
		for (my $i=1; $i < @v; $i++) {
		    printf SENDMAIL "  %-*s + %s\n", $maxlen, "", $v[$i];
		}
	    }
	};

	#
	# Another MIME section: stack traces (on warnings), if any
	#
	if (@warnings_traced) {
	    print  SENDMAIL <<"-";

--$b
Content-Type: text/plain; name="warnings"
Content-Description: Warnings, with Stack Traces

-

	    print  SENDMAIL "  * $_\n\n"		for @warnings_traced;
	    print  SENDMAIL "\n";
	}

	#
	# New MIME Section: environment
	#
	print  SENDMAIL <<"-";

--$b
Content-Type: text/plain; name="Environment"
Content-Description: Environment

-
	foreach my $v (sort keys %env) {  # FIXME: do in order of importance?
	    printf SENDMAIL "%-15s = %s\n", $v, $env{$v}||'[undef]';
	}

	#
	# Another MIME Section: included headers
	#
	print  SENDMAIL <<"-";

--$b
Content-Type: text/plain; name="%INC"
Content-Description: Included Headers

-
	foreach my $v (sort keys %INC) {
	    printf SENDMAIL "%-25s = %s\n", $v, $INC{$v}||'[undef]';
	}
	print  SENDMAIL "\n";

	# Final MIME separator, indicates the end
	print  SENDMAIL "--$b--\n";


	close SENDMAIL
	  or die "Error running sendmail; status = $?\n";
    };

    return $@;
}

# END   main notification function
###############################################################################
# BEGIN compile-time execution
#
# This is evaluated the moment our caller does 'use CGI::Alert'.
#

#
# Execute this on each warning
#
sub _warn {
    my $w = shift;

    # Things can get quickly out of hand.  We don't want to send an
    # unreadably long email... so just include the first 10 (FIXME)
    # warnings.  Anything more, and just include a count.
    if (@warnings < 10) {
	push @warnings, $w;
	push @warnings_traced, $w . _stack_trace;
    }
    else {
	push @warnings, '(....0 more...)'		if @warnings == 10;
	$warnings[-1] =~ s/(\d+)/$1 + 1/e;
    }

    # Always send the warning to STDERR (usually goes to error_log).
    # Include the base URL and the time.
    printf STDERR "[%s - %s] %s\n", $ME, scalar(localtime), $w
      unless $DEBUG_SENDMAIL;
};
$SIG{__WARN__} = \&_warn;

# (helper function for END and signal handlers
sub check_warnings(;$) {
    if (@warnings) {
	my $msg = "The following warnings were detected:";

	# Called with arguments?  Must be a signal.
	if (@_)		{ $msg = "Script was aborted by SIG$_[0]!  $msg"    }
	# Bad exit status?  Indicate so.
	elsif ($?)	{ $msg = "Script terminated with status $?!  $msg"  }

	notify("Warnings",
	       $msg,
	       "",
	       map { "  * $_" } @warnings);
    }
}


END { check_warnings }
$SIG{TERM} = \&check_warnings;


################
################  FATAL ERRORS.  This gets called on any 'die'.
################
sub _die($) {
    my $msg = shift;

    # Called inside an eval?  Pass it on.  This lets caller do things safely.
    die $msg if $^S;

    # Not an eval: die for real.

    # First of all: log to stderr (error_log) with script URL and time.
    printf STDERR "[%s - %s]: DIED: %s\n", $ME, scalar localtime, $msg
      unless $DEBUG_SENDMAIL;

    #
    # Display error message to remote (web) user.
    #

    # If caller has asked us to emit HTTP headers, do so now.
    if ($Emit_HTTP_Headers && !$DEBUG_SENDMAIL) {
	print  "Status: 500 Server Error\n",
               "Content-type: text/html; charset=ISO-8859-1\n",
               "\n";
    }

    # FIXME-someday: if inside a <table>, some browsers might not render this.
    # FIXME: do we want to escapeHTML($msg) ?
    print  <<EOP unless $DEBUG_SENDMAIL;
<h1><font color="red">Uh-Oh!</font></h1>
<p>
The script which was handling your request died, with the following error:
<p>
<pre>
    $msg
</pre>
<p>
If that indicates a problem which you can fix, please do so.
<p>
EOP

    # Generate a message body for the email we're going to send out
    my @text = ("The script died with:",
		"",
		"  $msg");
    if (@warnings) {
	push @text, "",
	            "In addition, the following warnings were detected:\n",
		    "",
		    map { "  * $_" } @warnings;
	@warnings = ();
    }

    # Send out email.  Inform web user about our emailing efforts.
    if (notify("FATAL ERRORS", @text)) {
	printf <<'-', maintainer		unless $DEBUG_SENDMAIL;
Otherwise, please send a note to the %s asking him/her to take a look.
I tried to send out a notification, but was unable to do so.
-
    } else {
	printf <<'-', maintainer		unless $DEBUG_SENDMAIL;
Otherwise, don't panic: I have sent a notification to the %s,
providing details of the error.
-
    }

    printf <<EOP, __PACKAGE__			unless $DEBUG_SENDMAIL;
<hr>
<address>Handled by <samp>%s v$VERSION</samp></address>
</body>
</html>
EOP

    exit 0;
};
$SIG{__DIE__} = \&_die;

# END   compile-time execution
###############################################################################
# BEGIN caller-accessible functions (not yet exported)

#######################
#  emit_http_headers  #  Caller can tell us when to emit 'Status', etc
#######################
sub emit_http_headers($) {
    $Emit_HTTP_Headers = 0 + $_[0];
}

# END   caller-accessible functions (not yet exported)
###############################################################################

1;

__END__


###############################################################################
#
# Documentation
#


=head1	NAME

CGI::Alert - report CGI script errors to maintainer

=head1	SYNOPSIS

    use CGI::Alert 'youraddress@your.domain';

That's all.  Everything else is transparent to your script.

=head1	DESCRIPTION

CGI::Alert will inform you by email of warnings and errors (from B<die>
or from exiting with nonzero status).

If the script terminates normally (exit status 0), and no warnings were
issued by the script or by Perl, CGI::Alert is a no-op.  It just consumes
resources but has no other effect.

If the script terminates normally, but has issued B<warnings> (either
directly via C<warn>, or by Perl itself from the C<warnings> pragma),
CGI::Alert will send you an email message with the first 10 of those
warnings, plus other details (see below).

If the script terminates via B<die>, CGI::Alert sends you an email
message with the details.  It also displays a big 'Uh-Oh' on the
remote web user's browser, informing him/her that an error has
occurred, and that the maintainer has been notified.

=head2	Maintainer Address

To specify the email address that will be notified of problems,
include it in the import list:

    use CGI::Alert 'esm@pobox.com';

or, more typically:

    use CGI::Alert 'esm';   # where 'esm' is a local account

=head2	Hiding Sensitive Data

Forms often contain sensitive data: passwords, credit card numbers,
next Tuesday's winning Lotto numbers.  CGI::Alert sends unencrypted
email, and you don't want these values being intercepted.

To exclude CGI parameters from the list sent by email, use
the B<hide=qr/.../> keyword on the import line:

    use CGI::Alert 'esm', 'hide=qr/credit/i';

If CGI::Alert encounters any parameter matching the given regex, it
substitutes B<[...]> (bracket, ellipsis, bracket) for its value:

    card_type       = Visa
    card_name       = Joe Bob
    credit_card_num = [...]

Multiple expressions are allowed, but must be specified
using one B<hide=> for each:

    use CGI::Alert 'esm', 'hide=qr/credit/i', 'hide=qr/passphrase/';

The default exclusion list is B<qr/[\b_-]passw/i>

=head2	Running under tilde URLs

CGI::Alert checks the C<REQUEST_URI> environment variable.  If it
detects a URL of the form B</~something> (slash, tilde, something)
CGI::Alert overrides the maintainer address, sending email only to
the B<something> following the tilde.

=head2	Specifics: email

On any C<die>, or if the CGI script has issued warnings, CGI::Alert
sends an email message to the maintainer with the following details:

=over 2

=item *

The B<URL> used to access the page

=item *

The B<error message> emitted by C<die>, with complete stack trace.

=item *

Any B<warnings> issued by the script (well, just the first 10), with full
stack trace.

=item *

The remote B<user name> (if known) and B<host name/address>

=item *

A full list of CGI B<parameters> passed to the script.  CGI::Alert
relies on the C<param> function provided by CGI.pm for this.

=item *

A full list of process B<environment variables> and their settings.

=item *

The expanded results of B<%INC>, showing all loaded modules and their
paths.  This can help when the problem is an obsolete version of a
module.

=back

=head2	Specifics: WWW

If the script C<die>s, a large heading will be shown in
red typeface, saying "Uh-Oh!".  The error will be displayed, along
with a note saying that the maintainer has been notified by email.

The remote (web) user is not informed of warnings.

=head1	REQUIREMENTS

CGI::Alert requires a properly configured C<sendmail> executable
in C</usr/sbin> or C</usr/lib>.  This does not need to be Sendmail
itself: Postfix, Exim, and other MTAs provide this executable.

=head1	BUGS

If the script dies before emitting the 'Status' and 'Content-Type'
headers (e.g. because of a compile-time syntax error), the remote
user will see the dreaded '500 Server Error' page.  Since this only
really happens when the CGI script fails to compile, this will only
ever be seen by the CGI script developer and hence is not a big deal.

As a workaround for this, you can do:

    CGI::Alert::emit_http_headers(1);

This tells CGI::Alert to emit HTTP Status and Content-type headers
before displaying the Uh-Oh message.

=head1	AUTHOR

Ed Santiago <esm@pobox.com>

=cut
