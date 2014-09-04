#pike __REAL_VERSION__

Stdio.Port port;
int portno;
string|int(0..0) interface;
function(.Request:void) callback;

//!
object|function|program request_program=.Request;

//! The simplest server possible. Binds a port and calls
//! a callback with @[request_program] objects.

//! @decl void create(function(.Request:void) callback)
//! @decl void create(function(.Request:void) callback,@
//!                   int portno, void|string interface)
void create(function(.Request:void) _callback,
            void|int _portno,
            void|string _interface,
            void|int share)
{
   portno=_portno;
   if (!portno) portno=80; // default HTTP port

   callback=_callback;
   interface=_interface;
   port=Stdio.Port();
   if (!port->bind(portno,new_connection,interface,share))
      error("HTTP.Server.Port: failed to bind port %s%d: %s\n",
	    interface?interface+":":"",
	    portno,strerror(port->errno()));
}

//! Closes the HTTP port.
void close()
{
   destruct(port);
   port=0;
}

void destroy() { close(); }

// the port accept callback

protected void new_connection()
{
    while( Stdio.File fd=port->accept() )
      request_program()->attach_fd(fd,this,callback);
}
