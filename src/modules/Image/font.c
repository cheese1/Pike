/* $Id: font.c,v 1.21 1997/11/11 22:17:48 mirar Exp $ */
#include <config.h>

#define SPACE_CHAR 'i'

/*
**! module Image
**! note
**!	$Id: font.c,v 1.21 1997/11/11 22:17:48 mirar Exp $
**! class font
**!
**! note
**! 	Short technical documentation on a font file:
**!	This object adds the text-drawing and -creation
**!	capabilities of the <ref>Image</ref> module.
**!
**!	For simple usage, see
**!	<ref>write</ref> and <ref>load</ref>.
**!
**!	other methods: <ref>baseline</ref>,
**!	<ref>height</ref>,
**!	<ref>set_xspacing_scale</ref>,
**!	<ref>set_yspacing_scale</ref>,
**!	<ref>text_extents</ref>
**!	
**!	<pre>
**!	       struct file_head 
**!	       {
**!		  unsigned INT32 cookie;   - 0x464f4e54 
**!		  unsigned INT32 version;  - 1 
**!		  unsigned INT32 chars;    - number of chars
**!		  unsigned INT32 height;   - height of font
**!		  unsigned INT32 baseline; - font baseline
**!		  unsigned INT32 o[1];     - position of char_head's
**!	       } *fh;
**!	       struct char_head
**!	       {
**!		  unsigned INT32 width;    - width of this character
**!		  unsigned INT32 spacing;  - spacing to next character
**!		  unsigned char data[1];   - pixmap data (1byte/pixel)
**!	       } *ch;
**!	</pre>
**!
**! see also: Image, Image.image
*/

/* Dump a font into a Roxen Font file (format version 2)

   On-disk syntax (everything in N.B.O), int is 4 bytes, a byte is 8 bits:

pos
 0   int cookie = 'FONT';     or 0x464f4e54
 4   int version = 2;         1 was the old version without the last four chars
 8   int numchars;            Always 256 in this version of the dump program
12   int height;              in (whole) pixels
16   int baseline;            in (whole) pixels
20   char direction;          1==right to left, 0 is left to right
21   char format;             Font format
22   char colortablep;        Colortable format
23   char kerningtablep;      Kerning table format

24   int offsets[numchars];   pointers into the data, realative to &cookie.
     [colortable]
     [kerningtable]

   At each offset:


0   int width;               in pixels
4   int spacing;             in 1/1000:th of a pixels
8   char data[];             Enough data to plot width * font->height pixels
                             Please note that if width is 0, there is no data.

Font formats:
 id type                                         efficiency with lucida 128
  0 Raw 8bit data                                not really.. :-)
  1 RLE encoded data,  char length, char data,   70% more compact than raw data
  2 ZLib compressed RLE encoded data             60% more compact than RLE

Colortable types:
  0 No colortable
  1 24bit RGB         (index->color, 256*3 bytes)
  2 24bit Greyscale   (index->color, 256*3 bytes)

Kerningtable types:
  0 No kerning table
  1 numchars*numchars entries, each a signed char with the kerning value
  2 numchar entries, each with a list of kerning pairs, like this:
     int len
     len * (short char, short value)
 */




#include "global.h"

#include <sys/types.h>
#include <sys/stat.h>

#ifdef HAVE_FCNTL_H
#include <fcntl.h>
#endif

#ifdef HAVE_SYS_FCNTL_H
#include <sys/fcntl.h>
#endif

#include <netinet/in.h>
#include <errno.h>

#include "config.h"

#include "stralloc.h"
#include "pike_macros.h"
#include "object.h"
#include "constants.h"
#include "interpret.h"
#include "svalue.h"
#include "array.h"
#include "threads.h"
#include "builtin_functions.h"

#include "image.h"
#ifdef HAVE_MMAP
#include <sys/mman.h>
#endif


static struct program *font_program;
extern struct program *image_program;

#define THIS (*(struct font **)(fp->current_storage))
#define THISOBJ (fp->current_object)

struct font 
{
   unsigned long height;      /* height of character rectangles */
   unsigned long baseline;    /* baseline of characters */
#ifdef HAVE_MMAP
   unsigned long mmaped_size; /* if 0 - not mmaped: just free() mem */
#endif
   void *mem;         /* pointer to mmaped/malloced memory */
   unsigned long chars;       /* number of characters */
  float xspacing_scale; /* Fraction of spacing to use */
  float yspacing_scale; /* Fraction of spacing to use */
  enum {
    J_LEFT,
    J_RIGHT,
    J_CENTER
  } justification;
   struct _char      
   {
      unsigned long width;   /* character rectangle has this width in pixels */
      unsigned long spacing; /* pixels to next character */
      unsigned char *pixels; /* character rectangle */
   } charinfo [1]; /* many!! */
};

/***************** init & exit *********************************/

static inline void free_font_struct(struct font *font)
{
   if (font)
   {
      if (font->mem)
      {
#ifdef HAVE_MMAP
	 munmap(font->mem,font->mmaped_size);
#else
	 free(font->mem);
#endif
      }
      free(font);
   }
}

static void init_font_struct(struct object *o)
{
  THIS=NULL;
}

static void exit_font_struct(struct object *obj)
{
   free_font_struct(THIS);
   THIS=NULL;
}

/***************** internals ***********************************/

static INLINE int char_space(struct font *this, unsigned char c)
{
  if(c==0x20)
    return (int)((float)(this->height*this->xspacing_scale)/4.5);
  else if(c==0x20+128)
    return (this->height*this->xspacing_scale)/18;
  return this->charinfo[c].spacing*this->xspacing_scale;
}

static INLINE int char_width(struct font *this, unsigned char c)
{
  if(c==0x20 || c==0x20+128)  return 0;
  return this->charinfo[c].width;
}  

#ifndef HAVE_MMAP
static INLINE int my_read(int from, char *buf, int towrite)
{
  int res;
  while((res = read(from, buf, towrite)) < 0)
  {
    switch(errno)
    {
     case EAGAIN: case EINTR:
      continue;

     default:
      res = 0;
      return 0;
    }
  }
  return res;
}
#endif

static INLINE long file_size(int fd)
{
  struct stat tmp;
  int res;
  if((!fstat(fd, &tmp)) &&
     (tmp.st_mode & S_IFREG)) {
    return res = tmp.st_size;
  }
  return -1;
}

static INLINE void write_char(struct _char *ci,
			      rgb_group *pos,
			      INT32 xsize,
			      INT32 height)
{
   rgb_group *nl;
   INT32 x,y;
   unsigned char *p;
   p=ci->pixels;

   for (y=height; y>0; y--)
   {
      nl=pos+xsize;
      for (x=(INT32)ci->width; x>0; x--)
      {
	 int r,c;
	 if((c=255-*p))
	   if ((r=pos->r+c)>255)
	     pos->r=pos->g=pos->b=255;
	   else
	     pos->r=pos->g=pos->b=r;
	 pos++;
	 p++;
      }
      pos=nl;
   }
}

/***************** methods *************************************/

/*
**! method object|int load(string filename)
**! 	Loads a font file to this font object.
**! returns zero upon failure, font object upon success
**! arg string filename
**!	Font file
**! see also: write
*/


void font_load(INT32 args)
{
   int fd;

   if (args<1 
       || sp[-args].type!=T_STRING)
      error("font->read: illegal or wrong number of arguments\n");
   
   if (THIS)
   {
      free_font_struct(THIS);
      THIS=NULL;
   }
   do 
   {
#ifdef FONT_DEBUG
     fprintf(stderr,"FONT open '%s'\n",sp[-args].u.string->str);
#endif
     fd = open(sp[-args].u.string->str,O_RDONLY);
   } while(fd < 0 && errno == EINTR);

   if (fd >= 0)
   {
      long size;
      struct font *new;

      size = file_size(fd);
      if (size > 0)
      {
	 new=THIS=(struct font *)xalloc(sizeof(struct font));

	 THREADS_ALLOW();
#ifdef HAVE_MMAP
	 new->mem = 
	    mmap(0,size,PROT_READ,MAP_SHARED,fd,0);
	 new->mmaped_size=size;
#else
	 new->mem = malloc(size);
	 if ((new->mem) && (!my_read(fd,new->mem,size))) {
	   free(new->mem);
	   new->mem = NULL;
	 }
#endif
	 THREADS_DISALLOW();

	 if (THIS->mem)
	 {
	    struct file_head 
	    {
	       unsigned INT32 cookie;
	       unsigned INT32 version;
	       unsigned INT32 chars;
	       unsigned INT32 height;
	       unsigned INT32 baseline;
	       unsigned INT32 o[1];
	    } *fh;
	    struct char_head
	    {
	       unsigned INT32 width;
	       unsigned INT32 spacing;
	       unsigned char data[1];
	    } *ch;

#ifdef FONT_DEBUG
	    fprintf(stderr,"FONT mapped ok\n");
#endif

	    fh=(struct file_head*)THIS->mem;

	    if (ntohl(fh->cookie)==0x464f4e54) /* "FONT" */
	    {
#ifdef FONT_DEBUG
	       fprintf(stderr,"FONT cookie ok\n");
#endif
	       if (ntohl(fh->version)==1)
	       {
		  unsigned long i;

#ifdef FONT_DEBUG
		  fprintf(stderr,"FONT version 1\n");
#endif

		  THIS->chars=ntohl(fh->chars);

		  new=malloc(sizeof(struct font)+
			     sizeof(struct _char)*(THIS->chars-1));
		  new->mem=THIS->mem;
#ifdef HAVE_MMAP
		  new->mmaped_size=THIS->mmaped_size;
#endif
		  new->chars=THIS->chars;
		  new->xspacing_scale = 1.0;
		  new->yspacing_scale = 1.0;
		  new->justification = J_LEFT;
		  free(THIS);
		  THIS=new;

		  THIS->height=ntohl(fh->height);
		  THIS->baseline=ntohl(fh->baseline);

		  for (i=0; i<THIS->chars; i++)
		  {
		     if (i*sizeof(INT32)<(unsigned long)size
			 && ntohl(fh->o[i])<(unsigned long)size
			 && ! ( ntohl(fh->o[i]) % 4) ) /* must be aligned */
		     {
			ch=(struct char_head*)
			   ((char *)(THIS->mem)+ntohl(fh->o[i]));
			THIS->charinfo[i].width = ntohl(ch->width);
			THIS->charinfo[i].spacing = ntohl(ch->spacing);
			THIS->charinfo[i].pixels = ch->data;
		     }
		     else /* illegal <tm> offset or illegal align */
		     {
#ifdef FONT_DEBUG
			fprintf(stderr,"FONT failed on char %02xh %d '%c'\n",
				i,i,i);
#endif
			free_font_struct(new);
			THIS=NULL;
			pop_n_elems(args);
			push_int(0);
			return;
		     }

		  }

		  close(fd);
		  pop_n_elems(args);
		  THISOBJ->refs++;
		  push_object(THISOBJ);   /* success */
#ifdef FONT_DEBUG
		  fprintf(stderr,"FONT successfully loaded\n");
#endif
		  return;
	       } /* wrong version */
#ifdef FONT_DEBUG
	       else fprintf(stderr,"FONT unknown version\n");
#endif
	    } /* wrong cookie */
#ifdef FONT_DEBUG
	    else fprintf(stderr,"FONT wrong cookie\n");
#endif
	 } /* mem failure */
#ifdef FONT_DEBUG
	 else fprintf(stderr,"FONT mem failure\n");
#endif
	 free_font_struct(THIS);
	 THIS=NULL;
      } /* size failure */
#ifdef FONT_DEBUG
      else fprintf(stderr,"FONT size failure\n");
#endif
      close(fd);
   } /* fd failure */
#ifdef FONT_DEBUG
   else fprintf(stderr,"FONT fd failure\n");
#endif

   pop_n_elems(args);
   push_int(0);
   return;
}

/*
**! method object write(string text,...)
**! 	Writes some text; thus creating an image object
**!	that can be used as mask or as a complete picture.
**! returns an <ref>Image.image</ref> object
**! arg string text, ...
**!	One or more lines of text.
**! see also: text_extents, load, Image.image->paste_mask, Image.image->paste_alpha_color
*/

void font_write(INT32 args)
{
   struct object *o;
   struct image *img;
   INT32 xsize=0,i,maxwidth2,j;
   int *width_of;
   unsigned char *to_write;
   int to_write_len;
   int c;
   struct font *this = (*(struct font **)(fp->current_storage));
   if (!this)
      error("font->write: no font loaded\n");

   maxwidth2=0;

   width_of=(int *)malloc((args+1)*sizeof(int));
   if(!width_of) error("Out of memory\n");

   for (j=0; j<args; j++)
   {
     if (sp[j-args].type!=T_STRING)
       error("font->write: illegal argument(s)\n");
     
     xsize = 0;
     to_write = (unsigned char*)sp[j-args].u.string->str;
     to_write_len = sp[j-args].u.string->len;
     for (i = 0; i < to_write_len; i++)
       xsize += char_space(this,to_write[i]);
     xsize += char_width(this,to_write[to_write_len-1])-char_space(this,to_write[to_write_len-1]);
     width_of[j]=xsize;
     if (xsize>maxwidth2) maxwidth2=xsize;
   }
   
   o = clone_object(image_program,0);
   img = ((struct image*)o->storage);
   img->xsize = maxwidth2;
   if(args>1)
     img->ysize = this->height+((double)this->height*(double)(args-1)*(double)this->yspacing_scale)+1;
   else
     img->ysize = this->height+1;
   img->rgb.r=img->rgb.g=img->rgb.b=255;
   img->img=malloc(img->xsize*img->ysize*sizeof(rgb_group));

   if (!img) { free_object(o); free(width_of); error("Out of memory\n"); }

   MEMSET(img->img,0,img->xsize*img->ysize*sizeof(rgb_group));

   for (j=0; j<args; j++)
   {
     to_write = (unsigned char *)sp[j-args].u.string->str;
     to_write_len = sp[j-args].u.string->len;
     switch(this->justification)
     {
      case J_LEFT:   xsize = 0; break;
      case J_RIGHT:  xsize = img->xsize-width_of[j]-1; break;
      case J_CENTER: xsize = img->xsize/2-width_of[j]/2-1; break;
     }
     if(xsize<0) xsize=0;

     THREADS_ALLOW();
     for (i = 0; i < to_write_len; i++)
     {
       c=*(to_write++);
/*     if(c<0) fatal("IDI compiler\n");*/
       if (c < (INT32)this->chars)
       {
	 if(char_width(this,c))
	   write_char(this->charinfo+c,
		      (img->img+xsize)+
		      (img->xsize*(int)(j*this->height*this->yspacing_scale)),
		      img->xsize,
		      this->height);
	 xsize += char_space(this, c);
       }
     }
     THREADS_DISALLOW();
   }
   free(width_of);

   pop_n_elems(args);
   push_object(o);
}

/*
**! method int height()
**! returns font height
**! see also: baseline, text_extents
*/

void font_height(INT32 args)
{
   pop_n_elems(args);
   if (THIS)
      push_int(THIS->height);
   else
      push_int(0);
}

/*
**! method array(int) text_extents(string text,...)
**!	Calculate extents of a text-image,
**!	that would be created by calling <ref>write</ref>
**!	with the same arguments.
**! returns an array of width and height 
**! arg string text, ...
**!	One or more lines of text.
**! see also: write, height, baseline
*/

void font_text_extents(INT32 args)
{
  INT32 xsize,i,maxwidth2,j;

  if (!THIS) error("font->text_extents: no font loaded\n");

  maxwidth2=0;

  for (j=0; j<args; j++) 
  {
    if (sp[j-args].type!=T_STRING) error("font->text_extents: illegal argument(s)\n");
    xsize = 0;
    for (i = 0; i < sp[j-args].u.string->len; i++)
      xsize += char_space(THIS, (unsigned char)sp[j-args].u.string->str[i]);
    xsize +=char_width(THIS,(unsigned char)sp[j-args].u.string->str[i-1])
            -char_space(THIS,(unsigned char)sp[j-args].u.string->str[i-1]);
    if (xsize>maxwidth2) maxwidth2=xsize;
  }
  pop_n_elems(args);
  push_int(maxwidth2);
  push_int(args * THIS->height * THIS->yspacing_scale);
  f_aggregate(2);
}



/*
**! method void set_xspacing_scale(float scale)
**! method void set_yspacing_scale(float scale)
**! 	Set spacing scale to write characters closer
**!	or more far away. This does not change scale
**!	of character, only the space between them.
**! arg float scale
**!	what scale to use
*/

void font_set_xspacing_scale(INT32 args)
{
  if(!THIS) error("font->set_xspacing_scale(FLOAT): No font loaded.\n");
  if(!args) error("font->set_xspacing_scale(FLOAT): No argument!\n");
  if(sp[-args].type!=T_FLOAT)
    error("font->set_xspacing_scale(FLOAT): Wrong type of argument!\n");

  THIS->xspacing_scale = (double)sp[-args].u.float_number;
/*fprintf(stderr, "Setting xspacing to %f\n", THIS->xspacing_scale);*/
  if(THIS->xspacing_scale < 0.0)
    THIS->xspacing_scale=0.1;
  pop_stack();
}


void font_set_yspacing_scale(INT32 args)
{
  if(!THIS) error("font->set_yspacing_scale(FLOAT): No font loaded.\n");
  if(!args) error("font->set_yspacing_scale(FLOAT): No argument!\n");
  if(sp[-args].type!=T_FLOAT)
    error("font->set_yspacing_scale(FLOAT): Wrong type of argument!\n");

  THIS->yspacing_scale = (double)sp[-args].u.float_number;
/*fprintf(stderr, "Setting yspacing to %f\n", THIS->yspacing_scale);*/
  if(THIS->yspacing_scale <= 0.0)
    THIS->yspacing_scale=0.1;
  pop_stack();
}


/*
**! method int baseline()
**! returns font baseline (pixels from top)
**! see also: height, text_extents
*/
void font_baseline(INT32 args)
{
   pop_n_elems(args);
   if (THIS)
      push_int(THIS->baseline);
   else
      push_int(0);
}

void font_set_center(INT32 args)
{
  pop_n_elems(args);
  if(THIS) THIS->justification=J_CENTER;
}

void font_set_right(INT32 args)
{
  pop_n_elems(args);
  if(THIS) THIS->justification=J_RIGHT;
}

void font_set_left(INT32 args)
{
  pop_n_elems(args);
  if(THIS) THIS->justification=J_LEFT;
}


/***************** global init etc *****************************/

/*

int load(string filename);  // load font file, true is success
object write(string text);  // new image object
int height();               // font heigth
int baseline();             // font baseline

*/

void init_font_programs(void)
{
   start_new_program();
   add_storage(sizeof(struct font*));

   add_function("load",font_load,
                "function(string:object|int)",0);

   add_function("write",font_write,
                "function(string:object)",0);

   add_function("height",font_height,
                "function(:int)",0);

   add_function("baseline",font_baseline,
                "function(:int)",0);
		
   add_function("extents",font_text_extents,
                "function(string ...:array(int))",0);
		
   add_function("text_extents",font_text_extents,
                "function(string ...:array(int))",0);
		
   add_function("set_x_spacing",font_set_xspacing_scale,
                "function(float:void)",0);

   add_function("set_y_spacing",font_set_yspacing_scale,
                "function(float:void)",0);

   add_function("center", font_set_center, "function(void:void)", 0);
   add_function("left", font_set_left, "function(void:void)", 0);
   add_function("right", font_set_right, "function(void:void)", 0);

   
   set_init_callback(init_font_struct);
   set_exit_callback(exit_font_struct);
  
   font_program=end_program();
   add_program_constant("font",font_program, 0);
}

void exit_font(void) 
{
  if(font_program)
  {
    free_program(font_program);
    font_program=0;
  }
}


