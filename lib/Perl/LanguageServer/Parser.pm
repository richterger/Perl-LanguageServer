package Perl::LanguageServer::Parser ;

use Moose::Role ;

use Coro ;
use Coro::AIO ;
use JSON ;
use File::Basename ;

use v5.18;

no warnings 'experimental' ;
no warnings 'uninitialized' ;


use Compiler::Lexer;
use Data::Dump qw{dump} ;

use constant SymbolKindFile => 1;
use constant SymbolKindModule => 2;
use constant SymbolKindNamespace => 3;
use constant SymbolKindPackage => 4;
use constant SymbolKindClass => 5;
use constant SymbolKindMethod => 6;
use constant SymbolKindProperty => 7;
use constant SymbolKindField => 8;
use constant SymbolKindConstructor => 9;
use constant SymbolKindEnum => 10;
use constant SymbolKindInterface => 11;
use constant SymbolKindFunction => 12;
use constant SymbolKindVariable => 13;
use constant SymbolKindConstant => 14;
use constant SymbolKindString => 15;
use constant SymbolKindNumber => 16;
use constant SymbolKindBoolean => 17;
use constant SymbolKindArray => 18;
use constant SymbolKindObject => 19;
use constant SymbolKindKey => 20;
use constant SymbolKindNull => 21;
use constant SymbolKindEnumMember => 22;
use constant SymbolKindStruct => 23;
use constant SymbolKindEvent => 24;
use constant SymbolKindOperator => 25;
use constant SymbolKindTypeParameter => 26;

sub parse_perl_source
    {
    my ($self, $uri, $source) = @_ ;    

    $source =~ s/\r//g ; #  Compiler::Lexer computes wrong line numbers with \r

    my $lexer  = Compiler::Lexer->new();
    my $tokens = $lexer->tokenize($source);
    
    cede () ;

    #print STDERR dump ($tokens), "\n" ;

    #my $modules = $lexer->get_used_modules($script);

    my @vars ;
    my $package = 'main::' ;
    my %state ;
    my $decl ;
    my $declline ;
    my $func ;
    my $parent ;
    my $top ;
    my $add ;

    foreach my $token (@$tokens)
        {
        $token -> {data} =~ s/\r$// ;
        print STDERR "token=", dump ($token), "\n" if ($Perl::LanguageServer::debug3) ;

        given ($token -> {name})
            {
            when (['VarDecl', 'OurDecl', 'FunctionDecl'])
                {
                $decl = $token -> {data}, 
                $declline = $token -> {line} ;   
                }
            when (/Var$/)
                {
                $top = $decl eq 'our' || !$parent?\@vars:$parent ;
                push @$top, 
                    {
                    name        => $token -> {data},
                    kind        => SymbolKindVariable,
                    containerName => $decl eq 'our'?$package:$func,     
                    ($decl?(defintion   => $decl):()),
                    } ; 
                $add = $top -> [-1] ;
                $token -> {line} = $declline if ($decl) ;
                $decl = undef ;
                }
            when ('LeftBrace')
                {
                if (@vars && $vars[-1]{kind} == SymbolKindVariable)
                    {
                    $vars[-1]{name} =~ s/^\$/%/ ;    
                    }
                }
            when ('LeftBracket')
                {
                if (@vars && $vars[-1]{kind} == SymbolKindVariable)
                    {
                    $vars[-1]{name} =~ s/^\$/@/ ;    
                    }
                }
            when ('Function')
                {
                $top = \@vars ;
                push @$top, 
                    {
                    name        => $token -> {data},
                    kind        => SymbolKindFunction,
                    containerName => $package,     
                    ($decl?(defintion   => $decl):()),
                    }  ;  
                $add = $top -> [-1] ;
                if ($decl)
                    {
                    $token -> {line} = $declline ;
                    $func = $token -> {data} ;
                    $parent = $vars[-1]{children} ||= [] ;
                    }
                $decl = undef ;
                }
            when ('Method')
                {
                $top = \@vars ;
                push @$top, 
                    {
                    name        => $token -> {data},
                    kind        => SymbolKindFunction,
                    containerName => $package,     
                    ($decl?(defintion   => $decl):()),
                    }  ;  
                $add = $top -> [-1] ;
                if ($decl)
                    {
                    $token -> {line} = $declline ;
                    $func = $token -> {data} ;
                    $parent = $vars[-1]{children} ||= [] ;
                    }
                $decl = undef ;
                }
            when (['Package', 'UseDecl'] )
                {
                $state{is} = $token -> {data} ;
                $state{module} = 1 ;
                }
            when (['ShortHashDereference', 'ShortArrayDereference'])
                {
                $state{scalar} = '$' ;    
                }
            when ('Key')
                {
                if (exists ($state{constant}))
                    {
                    $top = \@vars ;
                    push @$top, 
                        {
                        name        => $token -> {data},
                        kind        => SymbolKindConstant,
                        containerName => $package,     
                        defintion   => 1,
                        } ;    
                    $add = $top -> [-1] ;
                    }
                elsif (exists ($state{scalar}))
                    {
                    $top = $decl eq 'our' || !$parent?\@vars:$parent ;
                    push @$top, 
                        {
                        name        => $state{scalar} . $token -> {data},
                        kind        => SymbolKindVariable,
                        containerName => $decl eq 'our'?$package:$func,     
                        } ;    
                    $add = $top -> [-1] ;
                    }
                elsif ($token -> {data} ~~ ['has', 'class_has'])
                    {
                    $state{has} = 1 ;
                    }
                elsif ($token -> {data} =~ /^[a-z_][a-z0-9_]+$/i)
                    {
                    $top = \@vars ;
                    push @$top, 
                        {
                        name        => $token -> {data},
                        kind        => SymbolKindFunction,
                        }  ;  
                    $add = $top -> [-1] ;
                    }
                }
            when ('RawString')
                {
                if (exists ($state{has}))
                    {    
                    $top = \@vars ;
                    push @$top, 
                        {
                        name        => $token -> {data},
                        kind        => SymbolKindProperty,
                        containerName => $package,     
                        defintion   => 1,
                        } ;
                    $add = $top -> [-1] ;
                    }
                }
            when ('UsedName') 
                {
                if ($token -> {data} eq 'constant')
                    {
                    delete $state{module} ;
                    $state{constant} = 1 ;      
                    }
                else
                    {
                    $state{ns} = [$token->{data}] ;    
                    }    
                }
            when ('Namespace')
                {
                $state{ns} ||= [] ;
                push @{$state{ns}}, $token -> {data} ;
                }
            when ('NamespaceResolver')
                {
                # make sure it is not matched below
                }
            when (['SemiColon', 'Assign'])
                {
                $decl = undef ;
                continue ;    
                }    
            when ($token -> {data} =~ /^\W/)
                {
                if (exists ($state{ns}))
                    {
                    if ($state{module})
                        {
                        my $def ;
                        if ($state{is} eq 'package')
                            {
                            $def = 1 ;
                            $package = join ('::', @{$state{ns}}) ;    
                            $top = \@vars ;
                            push @$top, 
                                {
                                name        => $package,
                                kind        => SymbolKindModule,
                                #containerName => join ('::', @{$state{ns}}),
                                #($def?(defintion   => $def):()),
                                defintion => 1,
                                } ;   
                            $add = $top -> [-1] ;
                            }
                        else
                            {        
                            my $name = pop @{$state{ns}} ;
                            $top = \@vars ;
                            push @$top, 
                                {
                                name        => $name,
                                kind        => SymbolKindModule,
                                containerName => join ('::', @{$state{ns}}),
                                ($def?(defintion   => $def):()),
                                } ;   
                            $add = $top -> [-1] ;
                            }
                        }
                    else
                        {    
                        my $name = shift @{$state{ns}} ;
                        $top = \@vars ;
                        push @$top, 
                            {
                            name        => $name,
                            kind        => SymbolKindFunction,
                            containerName => join ('::', @{$state{ns}}),     
                            } ;   
                        $add = $top -> [-1] ;
                        }
                    }

                %state = () ;
                }
            }    
        if ($add)
            {
            if (!$uri)
                {
                $add ->  {line} = $token -> {line}-1 ;
                }
            else
                {    
                $add ->  {location} = { uri => $uri, range => { start => { line => $token -> {line}-1, character => 0 }, end => { line => $token -> {line}-1, character => 0 }}} ;
                }
            print STDERR "var=", dump ($add), "\n" if ($Perl::LanguageServer::debug3) ;
            $add = undef ;
            }
        }

    print STDERR dump (\@vars), "\n" if ($Perl::LanguageServer::debug3) ;

    return wantarray?(\@vars, $tokens):\@vars ;
    }


# ----------------------------------------------------------------------------

sub _parse_perl_source_cached
    {
    my ($self, $uri, $source, $path, $stats) = @_ ;    

    my $cachepath = $self -> state_dir .'/' . $path ;
    $self -> mkpath (dirname ($cachepath)) ;

    #print STDERR "$path -> cachepath=$cachepath\n" ;
    aio_stat ($cachepath) ;
    if (-e _)
        {
        my $mtime_cache = -M _ ;
        aio_stat ($path) ;
        my $mtime_src = -M _ ;
        #print STDERR "cache = $mtime_cache src = $mtime_src\n" ;
        if ($mtime_src > $mtime_cache)
            {
            #print STDERR "load from cache\n" ;    
            my $cache ;
            aio_load ($cachepath, $cache) ;
            my $vars = eval { $Perl::LanguageServer::json -> decode ($cache) ; } ;
            if (!$@)
                {
                $stats -> {loaded}++ ;
                return $vars ;
                }
            print "Loading of $cachepath failed, reparse file ($@)\n" ;    
            }
        }

    my $vars = $self -> parse_perl_source ($uri, $source) ;

    my $ifh = aio_open ($cachepath, IO::AIO::O_WRONLY | IO::AIO::O_TRUNC | IO::AIO::O_CREAT, 0664) or die "open $cachepath failed ($!)" ;
    aio_write ($ifh, undef, undef, $Perl::LanguageServer::json -> encode ($vars), 0) ;
    aio_close ($ifh) ;
    $stats -> {parsed}++ ;
    
    return $vars ;
    }



# ----------------------------------------------------------------------------

sub _parse_dir
    {
    my ($self, $server, $dir, $vars, $stats) = @_ ;

    my $text ;
    my $fn ;
    my $uri ;
    my $file_vars ;

    my $filefilter = $self -> file_filter_regex ;
    my $ignore_dir = $self -> ignore_dir ;

    my ($dirs, $files) = aio_scandir ($dir, 4) ;

    if ($dirs)
        {
        foreach my $d (sort @$dirs)
            {
            next if (exists $ignore_dir -> {$d}) ;
            $self -> _parse_dir ($server, $dir . '/' . $d, $vars, $stats) ;
            }
        }
    
    if ($files)
        {
        foreach my $f (sort @$files)
            {
            next if ($f !~ /$filefilter/) ; 

            $fn = $dir . '/' . $f ;
            aio_load ($fn, $text) ;

            $uri = $self -> uri_server2client ('file://' . $fn) ;
            #print STDERR "parse $fn -> $uri\n" ;
            $file_vars = $self -> _parse_perl_source_cached (undef, $text, $fn, $stats) ;
            $vars -> {$uri} =  $file_vars ;
            #print STDERR "done $fn\n" ;
            my $cnt = keys %$vars ;
            print STDERR "loaded $stats->{loaded} files, parsed $stats->{parsed} files, $cnt files\n" if ($cnt % 100 == 0) ;
            }
        }
    
    
    }

# ----------------------------------------------------------------------------

sub background_parser
    {
    my ($self, $server) = @_ ;

    my $channel = $self -> parser_channel ;
    $channel -> shutdown ; # end other parser
    cede ;
    
    $channel = $self -> parser_channel (Coro::Channel -> new) ;
    my $folders = $self -> folders ;
    print STDERR "background_parser folders = ", dump ($folders), "\n" ;
    %{$self -> symbols} = () ;

    my $stats = {} ;
    foreach my $dir (values %$folders)
        {
        $self -> _parse_dir ($server, $dir, $self -> symbols, $stats) ;
        cede ;
        }

    my $cnt = keys %{$self -> symbols} ;
    print STDERR "initial parsing done, loaded $stats->{loaded} files, parsed $stats->{parsed} files, $cnt files\n" ;

    my $filefilter = $self -> file_filter_regex ;

    while (my $item = $channel -> get)
        {
        my ($cmd, $uri) = @$item ;    

        my $fn = substr ($self -> uri_client2server ($uri), 7) ;
        next if (basename ($fn) !~ /$filefilter/) ; 

        my $text ;
        aio_load ($fn, $text) ;

        print STDERR "parse $fn -> $uri\n" ;
        my $file_vars = $self -> _parse_perl_source_cached (undef, $text, $fn, {}) ;
        $self -> symbols -> {$uri} =  $file_vars ;
        }

    print STDERR "background_parser quit\n" ;
    }    



1 ;


    