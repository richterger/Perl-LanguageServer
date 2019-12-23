var port = 13603;
var retries = 10 ;

if (process.argv.length > 2)
    port = parseInt(process.argv[2]) ;

var net = require("net");

var s = new net.Socket();

s.on("error", function()
    {
    if (retries-- > 0)
        {
        setTimeout (function () 
            {
            s.connect(port, '127.0.0.1') ;
            }, 200);
        }
    }) ;

s.on("connect", function()
    {
    process.stdin.on('data', function (data) 
        {
        s.write (data) ;
        });
    }) ;

s.on("data", function(data) 
    {
    process.stdout.write (data) ;
    });

s.connect(port, '127.0.0.1') ;

