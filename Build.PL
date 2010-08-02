use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'CGI::Alert',
    license             => 'perl',
    dist_author         => 'Eduardo Santiago <esm@cpan.org>',
    dist_version_from   => 'lib/CGI/Alert.pm',
    requires => {
        'Test::More' => 0,
        'Test::Differences' => 0,
    },
    add_to_cleanup      => [ 'CGI-Alert-*' ],
);

$builder->create_build_script();
