use 5.006;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'		=> 'CGI::Alert',
    'VERSION_FROM'	=> 'Alert.pm', # finds $VERSION
    'PREREQ_PM'		=> {}, # e.g., Module::Name => 1.1

    'ABSTRACT_FROM'     => 'Alert.pm', # retrieve abstract from module
    'AUTHOR'            => 'Eduardo Santiago <esm@pobox.com>',

    # (only for use by Ed): README is generated from README.in, so I don't
    # have to maintain the version in two places.  Make sure README is
    # up-to-date before we ship it.
    depend              => { distdir => 'README' },
);

sub MY::postamble {
    return <<'-';
README:	README.in Makefile
	sed -e "s/__VERSION__/$(VERSION)/" <$< >$@.tmp.$$ && mv -f $@.tmp.$$ $@

-
}
