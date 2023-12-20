
//! A simple FIFO queue.

#pike __REAL_VERSION__
#pragma strict_types

array|zero l;

//! Creates a queue with the initial items @[args] in it.
protected void create(mixed ...args)
{
  l = args;
}

protected int _sizeof()
{
  return sizeof(l);
}

protected array _values()
{
  return values(l);
}

//! @deprecated put
__deprecated__ void write(mixed ... items)
{
  l += items;
}

//! @decl void put(mixed ... items)
//! Adds @[items] to the queue.
//!
//! @seealso
//!   @[get()], @[peek()]
void put(mixed ... items)
{
  l += items;
}

//! @deprecated get
__deprecated__ mixed read()
{
  return get();
}

//! @decl mixed get()
//! Returns the next element from the queue, or @expr{UNDEFINED@} if
//! the queue is empty.
//!
//! @seealso
//!   @[peek()], @[put()]
mixed get()
{
  if( !sizeof(l) ) return UNDEFINED;
  mixed res = l[0];
  l = l[1..];
  return res;
}

//! Returns the next element from the queue without removing it from
//! the queue. Returns @expr{UNDEFINED@} if the queue is empty.
//!
//! @note
//!   Prior to Pike 9.0 this function returned a plain @expr{0@}
//!   when the queue was empty.
//!
//! @seealso
//!   @[get()], @[put()]
mixed peek()
{
  return sizeof(l)?l[0]:UNDEFINED;
}

//! Returns true if the queue is empty, otherwise zero.
int(0..1) is_empty()
{
  return !sizeof(l);
}

//! Empties the queue.
void flush()
{
  l = ({});
}

//! It is possible to cast ADT.Queue to an array.
protected mixed cast(string to)
{
  if( to=="array" )
    return l+({});
  return UNDEFINED;
}

protected string _sprintf(int t) {
  return t=='O' && sprintf("%O(%O)", this_program, l);
}
