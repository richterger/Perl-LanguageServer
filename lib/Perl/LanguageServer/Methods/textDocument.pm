package Perl::LanguageServer::Methods::textDocument ;

use Moose::Role ;

use Coro ;
use Coro::AIO ;
use Data::Dump qw{pp} ;
use AnyEvent::Util ;
use Encode;

no warnings 'uninitialized' ;


# ---------------------------------------------------------------------------

sub get_symbol_from_doc
    {
    my ($self, $workspace, $uri, $pos) = @_ ;

    my $files = $workspace -> files ;
    my $text = $files -> {$uri}{text} ;
    my $line = $pos -> {line} ;
    my $char = $pos -> {character} ;

    $text =~ /(?:.*?\n){$line}(.*?)\n/ ;
    my $data = $1 ;
    my $datapos = $-[1] ;
    $self -> logger ("line $line: <$data>\n") if ($Perl::LanguageServer::debug2) ;

    while ($data =~ /([a-zA-Z0-9_\$\%\@]+)/g)
        {
        my $pos = pos ($data) ;
        my $len = length ($1) ;
        $self -> logger ("word: <$1> pos: $pos len: $len\n") if ($Perl::LanguageServer::debug2) ;
        if ($char <= $pos && $char >= $pos - $len)
            {
            $self -> logger ("ok\n") if ($Perl::LanguageServer::debug2) ;
            return wantarray?($1, $datapos + $-[1]):$1 ;
            }
        }

    return ;
    }

# ---------------------------------------------------------------------------

sub get_symbol_before_left_parenthesis
    {
    my ($self, $workspace, $uri, $pos) = @_ ;

    my $files = $workspace -> files ;
    my $text = $files -> {$uri}{text} ;
    my $line = $pos -> {line} ;
    my $char = $pos -> {character} - 1 ;
    my $cnt  = 1 ;
    my $i ;
    my $endpos ;
    my @symbol ;
    my $symbolpos ;

    while ($line > 0)
        {
        $text =~ /(?:.*?\n){$line}(.*?)(?:\n|$)/ ;
        my $data = $1 ;
        $endpos //= $-[1] + $char ;
        my $datapos = $-[1] ;
        $self -> logger ("line $line: <$data>\n") if ($Perl::LanguageServer::debug2) ;
        $char = length ($data) - 1 if (!defined ($char)) ;
        for ($i = $char; $i >= 0; $i--)
            {
            my $c = substr ($data, $i, 1) ;
            if ($cnt == 0)
                {
                if ($c =~ /\w/)
                    {
                    push @symbol, $c ;
                    $symbolpos = $datapos + $i ;
                    next ;
                    }
                elsif (@symbol)
                    {
                    last ;
                    }
                elsif ($c eq ';')
                    {
                    return ;
                    }
                @symbol = () ;
                }
            if ($c eq '(')
                {
                $cnt--
                }
            elsif ($c eq ')')
                {
                $cnt++
                }
            elsif ($c eq ';')
                {
                return ;
                }
            }
        last if (@symbol) ;
        $line-- ;
        $char = undef ;
        }

    my $method ;
    for ($i = $symbolpos - 1 ; $i > 0; $i--)
        {
        my $c = substr ($text, $i, 1) ;
        if ($c eq '>' && substr ($text, $i - 1, 1) eq '-')
            {
            $method = 1 ;
            last ;
            }
        last if ($c !~ /\s/) ;
        }


    my $symbol = join ('', reverse @symbol) ;
    return ($symbol, substr ($text, $symbolpos, $endpos - $symbolpos + 1), $symbolpos, $endpos, $method) ;
    }

# ---------------------------------------------------------------------------

sub _rpcnot_didOpen
    {
    my ($self, $workspace, $req) = @_ ;

    my $files = $workspace -> files ;
    my $uri   = $req -> params -> {textDocument}{uri} ;
    my $text  = $req -> params -> {textDocument}{text} ;
    my $vers  = $req -> params -> {textDocument}{version} ;
    $files -> {$uri}{text} = $text ;
    $files -> {$uri}{version} = $vers ;
    delete $files -> {$uri}{vars} ;
    delete $files -> {$uri}{messages} if ($files -> {$uri}{messages_version} < $vers);

    $workspace -> check_perl_syntax ($workspace, $uri, $text) ;

    return ;
    }

# ---------------------------------------------------------------------------

sub _rpcnot_didChange
    {
    my ($self, $workspace, $req) = @_ ;

    my $files = $workspace -> files ;
    my $uri   = $req -> params -> {textDocument}{uri} ;
    my $text  = $req -> params -> {contentChanges}[0]{text} ;
    my $vers  = $req -> params -> {textDocument}{version} ;

    $files -> {$uri}{text} = $text ;
    $files -> {$uri}{version} = $vers ;
    delete $files -> {$uri}{vars} ;
    delete $files -> {$uri}{messages} if ($files -> {$uri}{messages_version} < $vers);

    $workspace -> check_perl_syntax ($workspace, $uri, $text) ;

    return ;
    }

# ---------------------------------------------------------------------------

sub _rpcnot_didClose
    {
    my ($self, $workspace, $req) = @_ ;

    my $files = $workspace -> files ;
    my $uri   = $req -> params -> {textDocument}{uri} ;
    delete $files -> {$uri}{text} ;
    delete $files -> {$uri}{version} ;
    delete $files -> {$uri}{vars} ;
    delete $files -> {$uri}{messages} ;

    return ;
    }

# ---------------------------------------------------------------------------

sub _rpcnot_didSave
    {
    my ($self, $workspace, $req) = @_ ;

    my $uri   = $req -> params -> {textDocument}{uri} ;
    $workspace -> parser_channel -> put (['save', $uri]) ;
    }

# ---------------------------------------------------------------------------

sub _filter_children
    {
    my ($self, $children, $show_local_vars) = @_ ;

    my @vars ;
    foreach my $v (@$children)
        {
        if (exists $v -> {definition} && (!exists $v -> {localvar} || $show_local_vars))
            {
            if (exists $v -> {children})
                {
                push @vars, { %$v, children => $self -> _filter_children ($v -> {children})} ;
                }
            else
                {
                push @vars, $v  ;
                }
            }
        }
    return \@vars ;
    }

# ---------------------------------------------------------------------------

sub _rpcreq_documentSymbol
    {
    my ($self, $workspace, $req) = @_ ;

    my $files = $workspace -> files ;
    my $uri   = $req -> params -> {textDocument}{uri} ;
    my $text  = $files -> {$uri}{text} ;
    return [] if (!$text) ;

    my $show_local_vars = $workspace -> show_local_vars ;
    my $vars  = $files -> {$uri}{vars} ;

    if (!$vars)
        {
        $vars = $workspace -> parse_perl_source ($uri, $text) ;
        $files -> {$uri}{vars} = $vars ;
        }
    my @vars ;
    foreach my $v (@$vars)
        {
        if (exists $v -> {definition} && (!exists $v -> {localvar} || $show_local_vars))
            {
            if (exists $v -> {children})
                {
                push @vars, { %$v, children => $self -> _filter_children ($v -> {children})} ;
                }
            else
                {
                push @vars, $v  ;
                }
            }
        }

    return \@vars ;
    }

# ---------------------------------------------------------------------------

sub _get_symbol
    {
    my ($self, $workspace, $req, $symbol, $name, $uri, $def_only, $vars) = @_ ;

    if (exists $symbol -> {children})
        {
        foreach my $s (@{$symbol -> {children}})
            {
            $self -> _get_symbol ($workspace, $req, $s, $name, $uri, $def_only, $vars) ;
            last if (@$vars > 500) ;
            }
        }

    return if ($symbol -> {name} ne $name) ;
    #print STDERR "name=$name symbols = ", pp ($symbol), "\n" ;
    return if ($def_only && !exists $symbol -> {definition}) ;
    my $line = $symbol -> {line} + 0 ;
    push @$vars, { uri => $uri, range => { start => { line => $line, character => 0 }, end => { line => $line, character => 0 }}} ;
    }

# ---------------------------------------------------------------------------

sub _get_symbols
    {
    my ($self, $workspace, $req, $def_only) = @_ ;

    my $pos = $req -> params -> {position} ;
    my $uri = $req -> params -> {textDocument}{uri} ;

    my $name = $self -> get_symbol_from_doc ($workspace, $uri, $pos) ;

    my $symbols = $workspace -> symbols ;
    #print STDERR "name=$name symbols = ", pp ($symbols), "\n" ;
    my $line ;
    my @vars ;

    if ($name)
        {
        foreach my $uri (keys %$symbols)
            {
            foreach my $symbol (@{$symbols->{$uri}})
                {
                $self -> _get_symbol ($workspace, $req, $symbol, $name, $uri, $def_only, \@vars) ;
                last if (@vars > 500) ;
                }
            }
        }

    return \@vars ;
    }

# ---------------------------------------------------------------------------

sub _rpcreq_definition
    {
    my ($self, $workspace, $req) = @_ ;

    return $self -> _get_symbols ($workspace, $req, 1) ;
    }

# ---------------------------------------------------------------------------

sub _rpcreq_references
    {
    my ($self, $workspace, $req) = @_ ;

    return $self -> _get_symbols ($workspace, $req, 0) ;
    }

# ---------------------------------------------------------------------------

sub _rpcreq_signatureHelp
    {
    my ($self, $workspace, $req) = @_ ;

    my $pos = $req -> params -> {position} ;
    my $uri = $req -> params -> {textDocument}{uri} ;
    $self -> logger (pp($req -> params)) ;

    my ($name, $expr, $symbolpos, $endpos, $method) = $self -> get_symbol_before_left_parenthesis ($workspace, $uri, $pos) ;

    return { signatures => [] } if (!$name) ;

    my $argnum = 0 ;
    while ($expr =~ /,/g)
        {
        $argnum++ ;
        }
    $argnum += ($method?1:0) ;

    my $symbols = $workspace -> symbols ;
    my $line ;
    my @vars ;

    foreach my $uri (keys %$symbols)
        {
        foreach my $symbol (@{$symbols->{$uri}})
            {
            next if ($symbol -> {name} ne $name) ;
            next if (!exists $symbol -> {definition}) ;
            next if (!exists $symbol -> {signature}) ;

            push @vars, $symbol -> {signature} ;
            last if (@vars > 200) ;
            }
        }

    $self -> logger (pp(\@vars))  if ($Perl::LanguageServer::debug2) ;

    my $signum = 0 ;
    my $context = $req -> params -> {context} ;
    if ($context)
        {
        $signum = $context -> {activeSignatureHelp}{activeSignature} // 0 ;
        }

    return { signatures => \@vars, activeParameter => $argnum + 0, activeSignature => $signum + 0 } ;
    }

# ---------------------------------------------------------------------------

sub _rpcreq_selectionRange
    {
    my ($self, $workspace, $req) = @_ ;

    my $pos = $req -> params -> {position} ;
    my $uri = $req -> params -> {textDocument}{uri} ;
    #$self -> logger (pp($req -> params)) ;

    my ($symbol, $offset) = $self -> get_symbol_from_doc ($workspace, $uri, $pos) ;

    $self -> logger ("sym = $symbol, $offset") ;

    return {} ;
    }

# ---------------------------------------------------------------------------

sub _rpcreq_rangeFormatting
    {
    my ($self, $workspace, $req) = @_ ;


    my $uri   = $req -> params -> {textDocument}{uri} ;
    my $range = $req -> params -> {range} ;
    #$workspace -> parser_channel -> put (['save', $uri]) ;
    $self -> logger (pp($req -> params)) ;
    my $fn = $uri ;
    $fn =~ s/^file:\/\/// ;
    $fn = $workspace -> file_client2server ($fn) ;

    #FormattingOptions
    # Size of a tab in spaces.
    #tabSize: uinteger;
    # Prefer spaces over tabs.
    #insertSpaces: boolean;
    # Trim trailing whitespace on a line.
    #trimTrailingWhitespace?: boolean;
    # Insert a newline character at the end of the file if one does not exist.
    # insertFinalNewline?: boolean;
    #trimFinalNewlines?: boolean;

    my $ret ;
    my $out ;
    my $errout ;

    my $files = $workspace -> files ;
    my $text  = $files -> {$uri}{text} ;

    my $start = $range -> {start}{line} ;
    my $end   = $range -> {end}{line} ;
    my $char  = $range -> {end}{character} ;
    $end-- if ($end > 0 && $char == 0) ;
    my $lines = $end - $start + 1 ;

    $text =~ /(?:.*?\n){$start}((?:.*?\n){$lines})/ ;
    my $range_text = $1 ;
    $range_text =~ s/\n$// ;
    if ($range_text eq '')
        {
        $text =~ /(?:.*?\n){$start}(.+)/s ;
        $range_text = $1 ;
        $range_text =~ s/\n$// ;
        }
    $self -> logger ('perltidy text: <' . $range_text . ">\n") if ($Perl::LanguageServer::debug2) ;

    return [] if ($range_text eq '') ;

    my $lang = $ENV{LANG} ;
    my $encoding = 'UTF-8' ;
    $encoding = $1 if ($lang =~ /\.(.+)/) ;
    $range_text = Encode::encode($encoding, $range_text) ;

    $self -> logger ("start perltidy $uri from line $start to $end\n") if ($Perl::LanguageServer::debug1) ;
    if ($^O =~ /Win/)
        {
        ($ret, $out, $errout) = $workspace -> run_open3 ($range_text, []) ;
        }
    else
        {
        $ret = run_cmd (['perltidy', '-st', '-se'],
            "<", \$range_text,
            ">", \$out,
            "2>", \$errout)
            -> recv ;
        }

    my $rc = $ret >> 8 ;
    $self -> logger ("perltidy rc=$rc errout=$errout\n") if ($Perl::LanguageServer::debug1) ;

    my @messages ;
    if ($rc != 0)
        {
        my $line ;
        my @lines = split /\n/, $errout ;
        my $lineno = 0 ;
        my $filename ;
        my $msg ;
        my $severity = 2 ;
        foreach $line (@lines)
            {
            next if ($line !~ /^(.+?):(\d+):(.+)/) ;

            $filename = $1 eq '<stdin>'?$fn:$1 ;
            $lineno   = $2 ;
            $msg      = $3 ;
            push @messages, [$filename, $lineno, $severity, $msg] if ($lineno && $msg) ;
            }
        }
    $workspace -> add_diagnostic_messages ($self, $uri, 'perltidy', \@messages, $files -> {$uri}{version} + 1) ;

    die "perltidy failed with exit code $rc" if ($rc != 0 && $out eq '') ;

    # make sure range is numeric
    $range -> {start}{line} += 0 ;
    $range -> {start}{character} = 0 ;
    $range -> {end}{line} += $range -> {end}{character} > 0?1:0 ;
    $range -> {end}{character} = 0 ;

    return [ { newText => Encode::decode($encoding, $out), range => $range } ] ;
    }

# ---------------------------------------------------------------------------

1 ;
