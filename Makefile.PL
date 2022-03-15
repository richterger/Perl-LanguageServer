use v5.18;
use strict;
use warnings;
use ExtUtils::MakeMaker;
use FindBin ;
use File::Basename ;
use Cwd;

=pod
my $mydir = getcwd;
my $lexer_make = $FindBin::Bin . '/p5-Compiler-Lexer/Build.PL' ;
my $lexer_inst = $FindBin::Bin . '/p5-Compiler-Lexer/Build' ;
if (-e $lexer_make)
    {
    print "Running $lexer_make to build included Compiler::Lexer\n\n" ;
    
    my $dir = dirname ($lexer_make) ;
    chdir $dir ;
    #system ("cd '$dir' && perl '$lexer_make'") and
    my $rc ;
    if (!($rc = system ('perl', $lexer_make)))
        {
        print "Install Compiler::Lexer\n\n" ;
        $rc = system ($lexer_inst, 'install') ;
        }
    if ($rc) 
        {    
        warn "Cannot run perl Build.PL for Compiler::Lexer. You need to install Compiler::Lexer from Github (do not use version 0.22)" ;    
        }
    chdir $mydir ;
    }
=cut

WriteMakefile(
    NAME             => 'Perl::LanguageServer',
    AUTHOR           => q{grichter <richter@ecos.de>},
    VERSION_FROM     => 'lib/Perl/LanguageServer.pm',
    ABSTRACT_FROM    => 'lib/Perl/LanguageServer.pm',
    LICENSE          => 'artistic_2',
    META_MERGE       => {
        'meta-spec'  => { version => 2 },
        resources   => {
            repository => {
                type => 'git',
                url => 'https://github.com/richterger/Perl-LanguageServer.git',
                web => 'https://github.com/richterger/Perl-LanguageServer',
            },
        },
    },
    PL_FILES         => {},
    MIN_PERL_VERSION => '5.014',
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '0',
    },
    BUILD_REQUIRES => {
        'Test::More' => '0',
    },
    PREREQ_PM => {
        'Moose'              => '0',
        'AnyEvent'           => '0',
        'IO::AIO'            => '0',
        'AnyEvent::AIO'      => '0',
        'Coro'               => '0',
        'JSON'               => '0',
        'Data::Dump'         => '0',
        'PadWalker'          => '0',
        'Scalar::Util'       => '0',
        'Class::Refresh'     => '0',
        'Compiler::Lexer'    => '0.23',
        'Hash::SafeKeys'     => '0',
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'Perl-LanguageServer-*' },
);
