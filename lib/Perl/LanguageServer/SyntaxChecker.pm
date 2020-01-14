package Perl::LanguageServer::SyntaxChecker ;

use Moose::Role ;
use strict ;

use Coro ;
use Coro::AIO ;
use Coro::Channel ;
use AnyEvent::Util ;
use File::Temp ;
use Encode ;

#use Proc::FastSpawn;

no warnings 'uninitialized' ;

# ---------------------------------------------------------------------------


has 'infile' =>
    (
    is => 'rw',
    isa => 'Str',
    lazy_build => 1,    
    ) ;

has 'outfile' =>
    (
    is => 'rw',
    isa => 'Str',
    lazy_build => 1,    
    ) ;

has 'checker_channel' =>
    (
    is => 'ro',
    isa => 'Coro::Channel',
    default => sub { Coro::Channel -> new }    
    ) ;

has 'checker2_channel' =>
    (
    is => 'ro',
    isa => 'Coro::Channel',
    default => sub { Coro::Channel -> new }    
    ) ;

# ---------------------------------------------------------------------------

sub _build_infile
    {
    my ($fh, $filename) = File::Temp::tempfile();
    close $fh ;

    return $filename ;
    }

# ---------------------------------------------------------------------------

sub _build_outfile
    {
    my ($fh, $filename) = File::Temp::tempfile();
    close $fh ;

    return $filename ;
    }


# ---------------------------------------------------------------------------

sub check_perl_syntax
    {
    my ($self, $workspace, $uri, $text) = @_ ;

    $self -> checker_channel -> put ([$uri, $text]) ;
    }


# ---------------------------------------------------------------------------

 sub run_open3
    {
    my ($self, $text, $inc) = @_ ;

    #return (0, undef, undef) ;

    my($wtr, $rdr, $err);

    require IPC::Open3 ;
    use Symbol 'gensym'; $err = gensym;
    my $pid = IPC::Open3::open3($wtr, $rdr, $err, $self -> perlcmd, '-c', @$inc) or die "Cannot run " . $self -> perlcmd ;
    $self -> logger ("write start pid=$pid\n") if ($Perl::LanguageServer::debug2) ;
    syswrite ($wtr,  $text . "\n__END__\n") ;
    $self -> logger ("close start\n") if ($Perl::LanguageServer::debug2) ; ;
    close ($wtr) ;
    $self -> logger ("write done\n") if ($Perl::LanguageServer::debug2) ; ; 

    my $out ;
    my $errout = join ('', <$err>) ;
    close $err ;
    close $rdr  ;
    $self -> logger ("closed\n") if ($Perl::LanguageServer::debug2) ; ;
    waitpid( $pid, 0 );
    my $rc = $? ;

    return ($rc, $out, $errout) ;
    }

# ---------------------------------------------------------------------------

sub background_checker
    {
    my ($self, $server) = @_ ;
    
    async
        {
        my $channel1 = $self -> checker_channel ;
        my $channel2 = $self -> checker2_channel ;

        my %timer ;
        while (my $cmd = $channel1 -> get)
            {
            my ($uri, $text) = @$cmd ;

            $timer{$uri} = AnyEvent->timer (after => 1.5, cb => sub
                {
                delete $timer{$uri} ;
                $channel2 -> put($cmd) ;    
                }) ;
            }

        } ;

    my $channel = $self -> checker2_channel ;

    while (my $cmd = $channel -> get)
        {
        my ($uri, $text) = @$cmd ;

        $text = eval { Encode::encode ('utf-8', $text) ; } ;
        $self -> logger ($@) if ($@) ;    
    
        my $ret ;
        my $errout ;
        my $out ;
        my $inc = $self -> perlinc ;
        my @inc ;
        @inc = map { ('-I', $_)} @$inc if ($inc) ;

        $self -> logger ("start perl -c\n") if ($Perl::LanguageServer::debug1) ; ;
        if ($^O =~ /Win/)
            {
            ($ret, $out, $errout) = $self -> run_open3 ($text, \@inc) ;
            }
        else
            {
            $ret = run_cmd ([$self -> perlcmd, '-c', @inc],
                "<", \$text,
                ">", \$out,
                "2>", \$errout)
                -> recv ;
            }

        my $rc = $ret >> 8 ;
        $self -> logger ("perl -c rc=$rc out=$out errout=$errout\n") if ($Perl::LanguageServer::debug1) ; ;

        my %diags = ( map { $_ => [] } @{$self -> files -> {$uri}{diags} || ['-'] } ) ;
        if ($rc != 0)
            {
            my $line ;
            my @lines = split /\n/, $errout ;
            my $lineno = 0 ;
            my $filename ;
            my $lastline = 1 ;
            my $msg ;
            foreach $line (@lines)
                {
                $line =~ s/\s*$// ;
                #print STDERR $line, "\n" ;
                next if ($line =~ /had compilation errors/) ;
                $filename = $1 if ($line =~ /at (.+?) line (\d+)[,.]/) ;
                $lineno   = $1 if ($line =~ / line (\d+)[,.]/) ;
                
                #print STDERR "line = $lineno  file=$filename\n" ;
                $msg .= $line ;
                if ($lineno)
                    {
                    if ($msg)
                        {    
                        my $diag =
                            {
                            #   range: Range;
                            #	severity?: number;
                            #	code?: number | string;
                            #   source?: string;
                            #   message: string;
                            #   relatedInformation?: DiagnosticRelatedInformation[];
                            range => { start => { line => $lineno-1, character => 0 }, end => { line => $lineno+0, character => 0 }},
                            message => $msg,
                            } ;
                        $diags{$filename} ||= [] ;
                        push @{$diags{$filename}}, $diag ;
                        }
                    $lastline = $lineno ;
                    $lineno = 0 ;
                    $msg    = '' ;
                    }    
                }
            }
        $self -> files -> {$uri}{diags} = [keys %diags] ;
        my $files = $self -> files ;
        foreach my $filename (keys %diags)
            {
            my $fnuri = !$filename || $filename eq '-'?$uri:$self -> uri_server2client ('file://' . $filename) ;
            my $result =
                {
                method => 'textDocument/publishDiagnostics',
                params => 
                    {
                    uri => $fnuri,
                    diagnostics => $diags{$filename},
                    },
                } ;
            #$self -> files -> {$fnuri}{diags} = $diags{$filename} ;

            $server -> send_notification ($result) ;
            }
        }
    }

=pod
sub xxxx
    {

    my $infile  = $self -> infile ;
    my $outfile = $self -> outfile ;

    print STDERR "infile=$infile outfile=$outfile\n" ;
    my $ifh = aio_open ($infile, IO::AIO::O_WRONLY | IO::AIO::O_TRUNC | IO::AIO::O_CREAT, 0600) or die "open $infile failed ($!)" ;
    aio_write ($ifh, undef, undef, $text, 0) ;
    aio_close ($ifh) ;

    # my $oldstderr ;
    # open($oldstderr,     ">&", \*STDERR) or die "Can't dup STDERR: $!";
    # open(STDERR, '>', $outfile)     or die "Can't redirect STDERR: $!";
    # print STDERR "start\n" ;
    # my $pid = spawnp "perl", ["perl", "-c", $infile]; 
    # open(STDERR, ">&", $oldstderr) or die "Can't dup \$oldstderr: $!";

    #my $pid = spawnp "cmd", ["cmd", '/C', "perl -c $infile 2> $outfile"]; 
    my $pid = spawnp $workspace -> perlcmd, [$workspace -> perlcmd, ]

    print STDERR "pid=$pid\n" ;

    my $w = AnyEvent->child (pid => $pid, cb => rouse_cb) ;
    my $ret = rouse_wait ;
    undef $w ;
    #Coro::AnyEvent::sleep (1) ;
    #print STDERR "wait\n" ;
    #waitpid ($pid, 0) ;
    #my $ret = $? ;
    my $rc = $ret >> 8;
    print STDERR "perl -c rc=$rc\n" ;

    #aio_slurp ($outfile, 0, 0, $errout) ;
    aio_load ($outfile, $errout) ;
    print STDERR "errout = $errout\n" ;

    #return ;

    #my ($rc, $diags) = rouse_wait ;   
    my $diags = [] ;

    print STDERR "---perl -c rc=$rc\n" ;
    
    return if ($rc == 0) ;

    my $result =
        {
        method => 'textDocument/publishDiagnostics',
        params => 
            {
            uri => $uri,
            diagnostics => $diags,
            },
        } ;

    $self -> send_notification ($result) ;
    }



    # my $cv = run_cmd [$workspace -> perlcmd, '-c'],
    #    # "<", \$text,
    #     "2>", \$errout
    #    ;
 
    # $cv->cb (sub 
    #     {
    #     shift->recv and die "perl -c failed";
 
    #     print "-------->$errout\n";
    #     });

    # return ;
=cut

=pod    

AnyEvent::Util::fork_call (sub  
   {
    print STDERR "open3 start c $$\n" ;
IO::AIO::reinit ;

  my($wtr, $rdr, $err);

    #return ;

#    use Symbol 'gensym'; $err = gensym;
    my $pid = open3($wtr, $rdr, $err, $workspace -> perlcmd, '-c') or die "Cannot run " . $workspace -> perlcmd ;
    #cede () ;
    print STDERR "write start pid=$pid\n" ;
    syswrite ($wtr,  $text . "\n__END__\n") ;
    print STDERR "close start\n" ;
    close ($wtr) ;
    print STDERR "write done\n" ;
    #my $errout = unblock $err ;
    my @diags ;
    my $line ;
#    while ($line = $errout -> readline)
    while ($line = <$rdr>)
        {
        $line =~ s/\s*$// ;
        print STDERR $line, "\n" ;
        next if ($line =~ /had compilation errors/) ;
        my $lineno = 0 ;
        $lineno = $1 if ($line =~ / line (\d+),/) ;
        my $diag =
            {
            #   range: Range;
            #	severity?: number;
            #	code?: number | string;
	        #   source?: string;
	        #   message: string;
	        #   relatedInformation?: DiagnosticRelatedInformation[];
            range => { start => { line => $lineno-1, character => 0 }, end => { line => $lineno+0, character => 0 }},
            message => $line,
            } ;
        push @diags, $diag ;
        }
    
    print STDERR "EOF\n" ;

    waitpid( $pid, 0 );
    my $rc = $? >> 8;
    print STDERR "perl -c rc=$rc\n" ;
    return ($rc, \@diags) ;
   }, rouse_cb ) ;

    my ($rc, $diags) = rouse_wait ;   
    
    print STDERR "---perl -c rc=$rc\n" ;
    
    return if ($rc == 0) ;

    my $result =
        {
        method => 'textDocument/publishDiagnostics',
        params => 
            {
            uri => $uri,
            diagnostics => $diags,
            },
        } ;

    $self -> send_notification ($result) ;
    }
=cut

1 ;
