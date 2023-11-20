package Perl::LanguageServer::Parser ;

use Moose::Role ;

use Coro ;
use Coro::AIO ;
use JSON ;
use File::Basename ;

use v5.16;

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

use constant CacheVersion => 5 ;


# ---------------------------------------------------------------------------

sub _get_docu
    {
    my ($self, $source, $line) = @_ ;

    my @docu ;
    my $in_pod ;
    while ($line-- >= 0)
        {
        my $src = $source -> [$line] ;
        if ($src =~ /^=cut/)
            {
            $in_pod = 1 ;
            next ;
            }

        if ($in_pod)
            {
            last if ($src =~ /^=pod/) ;
            next if ($src =~ /^=\w+\s*$/) ;
            $src =~ s/^=item /* / ;
            unshift @docu, $src ;
            }
        else
            {
            next if ($src =~ /^\s*$/) ;
            next if ($src =~ /^\s*#[-#+~= \t]+$/) ;
            last if ($src !~ /^\s*#(.*?)\s*$/) ;
            unshift @docu, $1 ;
            }
        }

    shift @docu while (@docu && ($docu[0] =~ /^\s*$/)) ;
    pop   @docu while (@docu && ($docu[-1] =~ /^\s*$/)) ;

    return join ("\n", @docu) ;
    }


# ---------------------------------------------------------------------------


sub parse_perl_source
    {
    my ($self, $uri, $source, $server) = @_ ;

    $source =~ s/\r//g ; #  Compiler::Lexer computes wrong line numbers with \r
    my @source = split /\n/, $source ;

    my $lexer  = Compiler::Lexer->new();
    my $tokens = $lexer->tokenize($source);

    cede () ;

    #$server -> logger (dump ($tokens) . "\n") ;

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
    my $func_param ;
    my $token_ndx = -1 ;
    my $brace_level = 0 ;
    my @stack ;
    my $beginchar = 0 ;
    my $endchar = 0 ;

    foreach my $token (@$tokens)
        {
        $token_ndx++ ;
        $token -> {data} =~ s/\r$// ;
        $server -> logger ("token=", dump ($token), "\n") if ($Perl::LanguageServer::debug3) ;

        if (exists $state{method_mod} && $token -> {name} eq 'RawString')
            {
            $token -> {name} = 'Function' ;
            delete $state{method_mod} ;
            }

        for($token -> {name})
            {
            if (/^(?:VarDecl|OurDecl|FunctionDecl)$/)
                {
                $decl = $token -> {data},
                $declline = $token -> {line} ;
                }
            elsif (/Var$/)
                {
                $top = $decl eq 'our' || !$parent?\@vars:$parent ;
                push @$top,
                    {
                    name        => $token -> {data},
                    kind        => SymbolKindVariable,
                    containerName => $decl eq 'our'?$package:$func,
                    ($decl?(definition   => $decl):()),
                    ($decl eq 'my'?(localvar => $decl):()),
                    } ;
                $add = $top -> [-1] ;
                $token -> {line} = $declline if ($decl) ;
                $decl = undef ;
                }
            elsif ($_ eq 'LeftBrace')
                {
                $brace_level++ ;
                $decl = undef ;
                if (@vars && $vars[-1]{kind} == SymbolKindVariable)
                    {
                    $vars[-1]{name} =~ s/^\$/%/ ;
                    }
                }
            elsif (/^(?:RightBrace|SemiColon)$/)
                {
                $brace_level-- if ($token -> {name} eq 'RightBrace') ;
                if (@stack > 0 && $brace_level == $stack[-1]{brace_level})
                    {
                    my $stacktop = pop @stack ;
                    $parent = $stacktop -> {parent} ;
                    $func   = $stacktop -> {func} ;
                    my $symbol = $stacktop -> {symbol} ;
                    my $start_line = $symbol -> {range}{start}{line} // $symbol -> {line} ;
                    $symbol ->  {range} = { start => { line => $start_line, character => 0 }, end => { line => $token -> {line}-1, character => 9999 }}
                        if (defined ($start_line)) ;
                    }
                if ($token -> {name} eq 'SemiColon')
                    {
                    $decl = undef ;
                    continue ;
                    }
                }
            elsif ($_ eq 'LeftBracket')
                {
                if (@vars && $vars[-1]{kind} == SymbolKindVariable)
                    {
                    $vars[-1]{name} =~ s/^\$/@/ ;
                    }
                }
            elsif (/^(?:Function|Method)$/)
                {
                if ($token -> {data} =~ /^\w/)
                    {
                    $top = !$parent?\@vars:$parent ;
                    push @$top,
                        {
                        name        => $token -> {data},
                        kind        => SymbolKindFunction,
                        containerName => @stack?$func:$package,
                        ($decl?(definition   => $decl):()),
                        }  ;
                    $func_param = $add = $top -> [-1] ;
                    if ($decl)
                        {
                        push @stack,
                            {
                            brace_level => $brace_level,
                            parent      => $parent,
                            func        => $func,
                            'package'   => $package,
                            symbol      => $add,
                            } ;
                        $token -> {line} = $declline ;
                        $func = $token -> {data} ;
                        $parent = $top -> [-1]{children} ||= [] ;
                        }
                    my $src = $source[$token -> {line}-1] ;
                    my $i ;
                    if ($src && ($i = index($src, $func) >= 0))
                        {
                        $beginchar = $i + 1 ;
                        $endchar   = $i + 1 + length ($func) ;
                        }
                    }
                $decl = undef ;
                }
            elsif ($_ eq 'ArgumentArray')
                {
                if ($func_param)
                    {
                    my @params ;
                    if ($tokens -> [$token_ndx - 1]{name} eq 'Assign' &&
                        $tokens -> [$token_ndx - 2]{name} eq 'RightParenthesis')
                        {
                        for (my $i = $token_ndx - 3; $i >= 0; $i--)
                            {
                            next if ($tokens -> [$i]{name} eq 'Comma') ;
                            last if ($tokens -> [$i]{name} !~ /Var$/) ;
                            push @params, $tokens -> [$i]{data} ;
                            }
                        my $func_doc = $self -> _get_docu (\@source, $func_param -> {range}{start}{line} // $func_param -> {line}) ;
                        my @parameters ;
                        foreach my $p (reverse @params)
                            {
                            push @parameters,
                                {
                                label => $p,
                                } ;
                            }
                        $func_param -> {detail} = '(' . join (',', reverse @params) . ')' ;
                        $func_param -> {signature} =
                            {
                            label => $func_param -> {name} . $func_param -> {detail},
                            documentation => $func_doc,
                            parameters => \@parameters
                            } ;
                        }
                    $func_param = undef ;
                    }
                }
            elsif ($_ eq 'Prototype')
                {
                if ($func_param)
                    {
                    my @params = split /\s*,\s*/, $token -> {data} ;
                    my $func_doc = $self -> _get_docu (\@source, $func_param -> {range}{start}{line} // $func_param -> {line}) ;
                    my @parameters ;
                    foreach my $p (@params)
                        {
                        push @parameters,
                            {
                            label => $p,
                            } ;
                        }
                    $func_param -> {detail} = '(' . join (',', @params) . ')' ;
                    $func_param -> {signature} =
                        {
                        label => $func_param -> {name} . $func_param -> {detail},
                        documentation => $func_doc,
                        parameters => \@parameters
                        } ;
                    $func_param = undef ;
                    }
                }
            elsif (/^(?:Package|UseDecl)$/)
                {
                $state{is} = $token -> {data} ;
                $state{module} = 1 ;
                }
            elsif (/^(?:ShortHashDereference|ShortArrayDereference)$/)
                {
                $state{scalar} = '$' ;
                }
            elsif ($_ eq 'Key')
                {
                if (exists ($state{constant}))
                    {
                    $top = \@vars ;
                    push @$top,
                        {
                        name        => $token -> {data},
                        kind        => SymbolKindConstant,
                        containerName => $package,
                        definition   => 1,
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
                elsif ($token -> {data} =~ /^(?:has|class_has)$/)
                    {
                    $state{has} = 1 ;
                    }
                elsif ($token -> {data} =~ /^(?:around|before|after)$/)
                    {
                    $state{method_mod} = 1 ;
                    $decl = $token -> {data},
                    $declline = $token -> {line} ;
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
            elsif ($_ eq 'RawString')
                {
                if (exists ($state{has}))
                    {
                    $top = \@vars ;
                    push @$top,
                        {
                        name        => $token -> {data},
                        kind        => SymbolKindProperty,
                        containerName => $package,
                        definition   => 1,
                        } ;
                    $add = $top -> [-1] ;
                    }
                }
            elsif ($_ eq 'UsedName')
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
            elsif($_ eq 'Namespace')
                {
                $state{ns} ||= [] ;
                push @{$state{ns}}, $token -> {data} ;
                }
            elsif ($_ eq 'NamespaceResolver')
                {
                # make sure it is not matched below
                }
            elsif ($_ eq 'Assign' or $token -> {data} =~ /^\W/)
                {
                if ($_ eq 'Assign')
                    {
                        $decl = undef ;
                    }

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
                                #($def?(definition   => $def):()),
                                definition => 1,
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
                                ($def?(definition   => $def):()),
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
                #$add ->  {location} = { uri => $uri, range => { start => { line => $token -> {line}-1, character => 0 }, end => { line => $token -> {line}-1, character => 0 }}} ;
                $add ->  {range} =         { start => { line => $token -> {line}-1, character => 0 },
                                             end   => { line => $token -> {line}-1, character => ($endchar?9999:0) }} ;
                $add -> {selectionRange} = { start => { line => $token -> {line}-1, character => $beginchar },
                                             end   => { line => $token -> {line}-1, character => $endchar }} ;
                $beginchar = $endchar = 0 ;
                }
            $server -> logger ("var=", dump ($add), "\n") if ($Perl::LanguageServer::debug3) ;
            $add = undef ;
            }
        }

    $server -> logger (dump (\@vars), "\n") if ($Perl::LanguageServer::debug3) ;

    return wantarray?(\@vars, $tokens):\@vars ;
    }


# ----------------------------------------------------------------------------

sub _parse_perl_source_cached
    {
    my ($self, $uri, $source, $path, $stats, $server) = @_ ;

    my $cachepath ;
    if (!$self -> disable_cache)
        {
        my $escpath = $path ;
        $escpath =~ s/:/%3A/ ;
        $cachepath = $self -> state_dir .'/' . $escpath ;
        $self -> mkpath (dirname ($cachepath)) ;

        #$server -> logger ("$path -> cachepath=$cachepath\n") ;
        aio_stat ($cachepath) ;
        if (-e _)
            {
            my $mtime_cache = -M _ ;
            aio_stat ($path) ;
            my $mtime_src = -M _ ;
            #$server -> logger ("cache = $mtime_cache src = $mtime_src\n") ;
            if ($mtime_src > $mtime_cache)
                {
                #$server -> logger ("load from cache\n") ;
                my $cache ;
                aio_load ($cachepath, $cache) ;
                my $cache_data = eval { $Perl::LanguageServer::json -> decode ($cache) ; } ;
                if ($@)
                    {
                    $self -> logger ("Loading of $cachepath failed, reparse file ($@)\n") ;
                    }
                elsif (ref ($cache_data) eq 'HASH')
                    {
                    if ($cache_data -> {version} == CacheVersion)
                        {
                        $stats -> {loaded}++ ;
                        return $cache_data -> {vars} ;
                        }
                    }
                }
            }
        }

    my $vars = $self -> parse_perl_source ($uri, $source, $server) ;

    if ($cachepath)
        {
        my $ifh = aio_open ($cachepath, IO::AIO::O_WRONLY | IO::AIO::O_TRUNC | IO::AIO::O_CREAT, 0664) or die "open $cachepath failed ($!)" ;
        aio_write ($ifh, undef, undef, $Perl::LanguageServer::json -> encode ({ version => CacheVersion, vars => $vars}), 0) ;
        aio_close ($ifh) ;
        }

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
            #$server -> logger ("parse $fn -> $uri\n") ;
            $file_vars = $self -> _parse_perl_source_cached (undef, $text, $fn, $stats, $server) ;
            $vars -> {$uri} =  $file_vars ;
            #$server -> logger ("done $fn\n") ;
            my $cnt = keys %$vars ;
            $server -> logger ("loaded $stats->{loaded} files, parsed $stats->{parsed} files, $cnt files\n") if ($cnt % 100 == 0) ;
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
    $server -> logger ("background_parser folders = ", dump ($folders), "\n") ;
    %{$self -> symbols} = () ;

    my $stats = {} ;
    foreach my $dir (values %$folders)
        {
        $self -> _parse_dir ($server, $dir, $self -> symbols, $stats) ;
        cede ;
        }

    my $cnt = keys %{$self -> symbols} ;
    $server -> logger ("initial parsing done, loaded $stats->{loaded} files, parsed $stats->{parsed} files, $cnt files\n") ;

    my $filefilter = $self -> file_filter_regex ;

    while (my $item = $channel -> get)
        {
        my ($cmd, $uri) = @$item ;

        my $fn = substr ($self -> uri_client2server ($uri), 7) ;
        next if (basename ($fn) !~ /$filefilter/) ;

        my $text ;
        aio_load ($fn, $text) ;

        $server -> logger ("parse $fn -> $uri\n") ;
        my $file_vars = $self -> _parse_perl_source_cached (undef, $text, $fn, {}, $server) ;
        $self -> symbols -> {$uri} =  $file_vars ;
        }

    $server -> logger ("background_parser quit\n") ;
    }



1 ;



