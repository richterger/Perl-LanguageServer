var PORT = 13603;

var net = require("net");

var s = new net.Socket();

s.on("data", function(data) {
    process.stdout.write (data) ;
});
s.connect(PORT, '127.0.0.1', function(){
    process.stdin.on('data', function (data) {
        s.write (data) ;
    });
});

