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

 sub run_win32
    {
    my ($self, $text, $inc) = @_ ;


    return (0, undef, undef) ; # disable for now on windows

    my $infile  = $self -> infile ;
    my $outfile = $self -> outfile ;

    print STDERR "infile=$infile outfile=$outfile\n" ;
    my $ifh = aio_open ($infile, IO::AIO::O_WRONLY | IO::AIO::O_TRUNC | IO::AIO::O_CREAT, 0600) or die "open $infile failed ($!)" ;
    aio_write ($ifh, undef, undef, $text, 0) ;
    aio_close ($ifh) ;

    print STDERR "run ", $self -> perlcmd . " -c  @$inc $infile 2> $outfile", "\n" ;

    # use Win32::Process ;

    # my $cmd = $self -> perlcmd . " -c  @$inc $infile" ;

    # print STDERR $cmd, "\n" ;

    # my $ProcessObj ;
    my $rc ;
    # Win32::Process::Create($ProcessObj,

    #                     $self -> perlcmd,
    #                     $cmd,
    #                     0,
    #                     NORMAL_PRIORITY_CLASS,
    #                     ".");

    # print STDERR "wait\n" ;

    # $ProcessObj->Wait(5000) ;

    print STDERR "done\n" ;

    my $errout ;
    my $out ;
    aio_load ($outfile, $errout) ;
    print STDERR "errout = $errout\n" ;

    return ($rc, $out, $errout) ;
    }


# ---------------------------------------------------------------------------

 sub run_system
    {
    my ($self, $text, $inc) = @_ ;

    my $infile  = $self -> infile ;
    my $outfile = $self -> outfile ;

    local $SIG{CHLD} = 'DEFAULT' ;
    local $SIG{PIPE} = 'DEFAULT' ;

    print STDERR "infile=$infile outfile=$outfile\n" ;
    my $ifh = aio_open ($infile, IO::AIO::O_WRONLY | IO::AIO::O_TRUNC | IO::AIO::O_CREAT, 0600) or die "open $infile failed ($!)" ;
    aio_write ($ifh, undef, undef, $text, 0) ;
    aio_close ($ifh) ;

    print STDERR "run ", $self -> perlcmd . " -c  @$inc $infile 2> $outfile", "\n" ;
    my $rc = system ($self -> perlcmd . " -c  @$inc $infile 2> $outfile") ;
    print STDERR "done\n" ;

    my $errout ;
    my $out ;
    aio_load ($outfile, $errout) ;
    print STDERR "errout = $errout\n" ;

    return ($rc, $out, $errout) ;
    }

# ---------------------------------------------------------------------------

 sub run_open3
    {
    my ($self, $text, $inc) = @_ ;

    #return (0, undef, undef) ;

    my($wtr, $rdr, $err);

    require IPC::Open3 ;
    use Symbol 'gensym'; $err = gensym;
    $self -> logger ("open3\n") if ($Perl::LanguageServer::debug2) ;
    my $pid = IPC::Open3::open3($wtr, $rdr, $err, $self -> perlcmd, '-c', @$inc) or die "Cannot run " . $self -> perlcmd ;
    $self -> logger ("write start pid=$pid\n") if ($Perl::LanguageServer::debug2) ;
    syswrite ($wtr,  $text . "\n__END__\n") ;
    $self -> logger ("close start\n") if ($Perl::LanguageServer::debug2) ;
    close ($wtr) ;
    $self -> logger ("write done\n") if ($Perl::LanguageServer::debug2) ;

    my $out ;
    my $errout = join ('', <$err>) ;
    close $err ;
    close $rdr  ;
    $self -> logger ("closed\n") if ($Perl::LanguageServer::debug2) ;
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

        my $fn = $uri ;
        $fn =~ s/^file:\/\/// ;
        $fn = $self -> file_client2server ($fn) ;
        $text = "local \$0; BEGIN { \$0 = '$fn'; if (\$INC{'FindBin.pm'}) { FindBin->again(); } }\n# line 1 \"$fn\"\n" . $text;

        my $ret ;
        my $errout ;
        my $out ;
        my $inc = $self -> perlinc ;
        my @inc ;
        @inc = map { ('-I', $_)} @$inc if ($inc) ;

        my @syntax_options ;
        if ($self -> use_taint_for_syntax_check) {
            @syntax_options = ('-T') ;
        }

        $self -> logger ("start perl @syntax_options -c @inc for $uri\n") if ($Perl::LanguageServer::debug1) ;
        if ($^O =~ /Win/)
            {
#            ($ret, $out, $errout) = $self -> run_open3 ($text, \@inc) ;
            ($ret, $out, $errout) = $self -> run_win32 ($text, \@inc) ;
            }
        else
            {
            $ret = run_cmd ([$self -> perlcmd, @syntax_options, '-c', @inc],
                "<", \$text,
                ">", \$out,
                "2>", \$errout)
                -> recv ;
            }

        my $rc = $ret >> 8 ;
        $self -> logger ("perl -c rc=$rc out=$out errout=$errout\n") if ($Perl::LanguageServer::debug1) ;

        my @messages ;
        if ($rc != 0)
            {
            my $line ;
            my @lines = split /\n/, $errout ;
            my $lineno = 0 ;
            my $filename ;
            my $lastline = 1 ;
            my $msg ;
            my $severity = 1 ;
            foreach $line (@lines)
                {
                $line =~ s/\s*$// ;
                #print STDERR $line, "\n" ;
                next if ($line =~ /had compilation errors/) ;
                $filename = $1 if ($line =~ /at (.+?) line (\d+)[,.]/) ;
                #print STDERR "line = $lineno  file=$filename fn=$fn\n" ;
                $filename ||= $fn ;
                $lineno   = $1 if ($line =~ / line (\d+)[,.]/) ;

                $msg .= $line ;
                if ($lineno)
                    {
                    push @messages, [$filename, $lineno, $severity, $msg] if ($msg) ;
                    $lastline = $lineno ;
                    $lineno = 0 ;
                    $msg    = '' ;
                    }
                }
            }

        $self -> add_diagnostic_messages ($server, $uri, 'perl syntax', \@messages) ;
        }
    }

1;

__END__

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

1 ;
