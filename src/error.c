/*\
||| This file a part of Pike, and is copyright by Fredrik Hubinette
||| Pike is distributed as GPL (General Public License)
||| See the files COPYING and DISCLAIMER for more information.
\*/
#include "global.h"
#include "pike_macros.h"
#include "error.h"
#include "interpret.h"
#include "stralloc.h"
#include "builtin_functions.h"
#include "array.h"
#include "object.h"
#include "main.h"
#include "builtin_functions.h"
#include "backend.h"
#include "operators.h"

RCSID("$Id: error.c,v 1.22 1998/11/22 11:02:44 hubbe Exp $");

#undef ATTRIBUTE
#define ATTRIBUTE(X)

JMP_BUF *recoveries=0;

JMP_BUF *init_recovery(JMP_BUF *r DEBUG_LINE_ARGS)
{
#ifdef PIKE_DEBUG
  r->line=line;
  r->file=file;
#endif
  r->fp=fp;
  r->sp=sp-evaluator_stack;
  r->mark_sp=mark_sp - mark_stack;
  r->previous=recoveries;
  r->onerror=0;
  r->severity=THROW_ERROR;
  recoveries=r;
  return r;
}

void pike_throw(void) ATTRIBUTE((noreturn))
{
  while(recoveries && throw_severity > recoveries->severity)
  {
    while(recoveries->onerror)
    {
      (*recoveries->onerror->func)(recoveries->onerror->arg);
      recoveries->onerror=recoveries->onerror->previous;
    }
    
    recoveries=recoveries->previous;
  }

  if(!recoveries)
    fatal("No error recovery context.\n");

#ifdef PIKE_DEBUG
  if(sp - evaluator_stack < recoveries->sp)
    fatal("Stack error in error.\n");
#endif

  while(fp != recoveries->fp)
  {
#ifdef PIKE_DEBUG
    if(!fp)
      fatal("Popped out of stack frames.\n");
#endif
    free_object(fp->current_object);
    free_program(fp->context.prog);
    if(fp->context.parent)
      free_object(fp->context.parent);
    
    fp = fp->parent_frame;
  }

  pop_n_elems(sp - evaluator_stack - recoveries->sp);
  mark_sp = mark_stack + recoveries->mark_sp;

  while(recoveries->onerror)
  {
    (*recoveries->onerror->func)(recoveries->onerror->arg);
    recoveries->onerror=recoveries->onerror->previous;
  }

  longjmp(recoveries->recovery,1);
}

void push_error(char *description)
{
  push_text(description);
  f_backtrace(0);
  f_aggregate(2);
}

struct svalue throw_value = { T_INT };
int throw_severity;

static const char *in_error;
/* FIXME: NOTE: This function uses a static buffer.
 * Check sizes of arguments passed!
 */
void va_error(const char *fmt, va_list args) ATTRIBUTE((noreturn))
{
  char buf[4096];
  if(in_error)
  {
    const char *tmp=in_error;
    in_error=0;
    fatal("Recursive error() calls, original error: %s",tmp);
  }

  in_error=buf;

#ifdef HAVE_VSNPRINTF
  vsnprintf(buf, 4090, fmt, args);
#else /* !HAVE_VSNPRINTF */
  VSPRINTF(buf, fmt, args);
#endif /* HAVE_VSNPRINTF */

  if(!recoveries)
  {
#ifdef PIKE_DEBUG
    dump_backlog();
#endif

    fprintf(stderr,"No error recovery context!\n%s",buf);
    exit(99);
  }

  if((long)strlen(buf) >= (long)sizeof(buf))
    fatal("Buffer overflow in error()\n");
  
  push_error(buf);
  free_svalue(& throw_value);
  throw_value = *--sp;
  throw_severity=THROW_ERROR;

  in_error=0;
  pike_throw();  /* Hope someone is catching, or we will be out of balls. */
}

void new_error(const char *name, const char *text, struct svalue *oldsp,
	       INT32 args, const char *file, int line) ATTRIBUTE((noreturn))
{
  int i;

  if(in_error)
  {
    const char *tmp=in_error;
    in_error=0;
    fatal("Recursive error() calls, original error: %s",tmp);
  }

  in_error=text;

  if(!recoveries)
  {
#ifdef PIKE_DEBUG
    dump_backlog();
#endif

    fprintf(stderr,"No error recovery context!\n%s():%s",name,text);
    exit(99);
  }

  push_text(text);

  f_backtrace(0);

  if (file) {
    push_text(file);
    push_int(line);
  } else {
    push_int(0);
    push_int(0);
  }
  push_text(name);

  for (i=-args; i; i++) {
    push_svalue(oldsp + i);
  }

  f_aggregate(args + 3);
  f_aggregate(1);

  f_add(2);

  f_aggregate(2);

  free_svalue(& throw_value);
  throw_value = *--sp;
  throw_severity=THROW_ERROR;

  in_error=0;
  pike_throw();  /* Hope someone is catching, or we will be out of balls. */
}

void exit_on_error(void *msg)
{
#ifdef PIKE_DEBUG
  dump_backlog();
#endif
  fprintf(stderr,"%s\n",(char *)msg);
  exit(1);
}

void fatal_on_error(void *msg)
{
#ifdef PIKE_DEBUG
  dump_backlog();
#endif
  fprintf(stderr,"%s\n",(char *)msg);
  abort();
}

void error(const char *fmt,...) ATTRIBUTE((noreturn,format (printf, 1, 2)))
{
  va_list args;
  va_start(args,fmt);
  va_error(fmt,args);
  va_end(args);
}


void debug_fatal(const char *fmt, ...) ATTRIBUTE((noreturn,format (printf, 1, 2)))
{
  va_list args;
  static int in_fatal = 0;

  va_start(args,fmt);
  /* Prevent double fatal. */
  if (in_fatal)
  {
    (void)VFPRINTF(stderr, fmt, args);
    abort();
  }
  in_fatal = 1;
#ifdef PIKE_DEBUG
  dump_backlog();
#endif

  (void)VFPRINTF(stderr, fmt, args);

  d_flag=t_flag=0;
  push_error("Attempting to dump backlog (may fail).\n");
  APPLY_MASTER("describe_backtrace",1);
  if(sp[-1].type==T_STRING)
    write_to_stderr(sp[-1].u.string->str, sp[-1].u.string->len);

  fflush(stderr);
  abort();
}
