/* Prototypes of glmt's OpenGL entry points, from gl_impl.inc. */
#ifndef GLMT_API_H
#define GLMT_API_H

#include "gl.h"

#define GL_IMPL(ret, name, params) ret glmt_##name params;
#include "gl_impl.inc"
#undef GL_IMPL

#endif
