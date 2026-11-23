/* The matrix stacks. Matrices are OpenGL's: 16 floats, column-major. */
#include <math.h>
#include <string.h>

#include "api.h"
#include "internal.h"

void glmt_matrix_identity(float m[16])
{
    memset(m, 0, 16 * sizeof(float));
    m[0] = m[5] = m[10] = m[15] = 1.0f;
}

/* out = a * b; out may be a or b */
void glmt_matrix_multiply(float out[16], const float a[16], const float b[16])
{
    float r[16];
    for (int col = 0; col < 4; col++)
        for (int row = 0; row < 4; row++)
            r[col * 4 + row] = a[0 * 4 + row] * b[col * 4 + 0] + a[1 * 4 + row] * b[col * 4 + 1] +
                               a[2 * 4 + row] * b[col * 4 + 2] + a[3 * 4 + row] * b[col * 4 + 3];
    memcpy(out, r, sizeof(r));
}

bool glmt_matrix_invert(float out[16], const float m[16])
{
    double inv[16], det;

    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] +
             m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] -
             m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] +
             m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] -
              m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] -
             m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] +
             m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] -
             m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] +
              m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] +
             m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] -
             m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] +
              m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] -
              m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] -
             m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] +
             m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] -
              m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] +
              m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

    det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (det == 0.0) return false;
    det = 1.0 / det;
    for (int i = 0; i < 16; i++) out[i] = (float)(inv[i] * det);
    return true;
}

void glmt_matrix_init(struct glmt_context *c)
{
    c->modelview.m = c->modelview_store;
    c->modelview.max = GLMT_MODELVIEW_STACK;
    c->projection.m = c->projection_store;
    c->projection.max = GLMT_PROJECTION_STACK;
    glmt_matrix_identity(c->modelview_store[0]);
    glmt_matrix_identity(c->projection_store[0]);
    for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++)
    {
        c->texture_matrix[u].m = c->texture_store[u];
        c->texture_matrix[u].max = GLMT_TEXTURE_STACK;
        glmt_matrix_identity(c->texture_store[u][0]);
    }
    c->color_matrix.m = c->color_store;
    c->color_matrix.max = 2;
    glmt_matrix_identity(c->color_store[0]);
    c->matrix_mode = GL_MODELVIEW;
}

static struct glmt_matrix_stack *current_stack(struct glmt_context *c)
{
    switch (c->matrix_mode)
    {
    case GL_PROJECTION: return &c->projection;
    case GL_TEXTURE: return &c->texture_matrix[c->active_unit];
    case GL_COLOR: return &c->color_matrix;
    default: return &c->modelview;
    }
}

static float *current_matrix(struct glmt_context *c)
{
    struct glmt_matrix_stack *s = current_stack(c);

    /* The texture matrix is not applied: id Tech 3 computes its texture coordinates itself and
     * leaves it at identity. Anything else would draw wrong, so say so. (glLoadIdentity does not
     * come through here.) */
    if (c->matrix_mode == GL_TEXTURE) GLMT_LOG_ONCE("glmt: the texture matrix is changed, and glmt does not apply it");
    if (c->matrix_mode == GL_COLOR) GLMT_LOG_ONCE("glmt: the color matrix is changed, and glmt does not apply it");
    return s->m[s->depth];
}

static void multiply_current(struct glmt_context *c, const float m[16])
{
    float *top = current_matrix(c);
    glmt_matrix_multiply(top, top, m);
}

void glmt_glMatrixMode(GLenum mode)
{
    GLMT_CONTEXT();
    GLMT_TRACE_ARGS("mode 0x%04x", mode);
    if (mode != GL_MODELVIEW && mode != GL_PROJECTION && mode != GL_TEXTURE && mode != GL_COLOR)
    {
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    c->matrix_mode = mode;
}

void glmt_glLoadIdentity(void)
{
    GLMT_CONTEXT();
    struct glmt_matrix_stack *s = current_stack(c);
    glmt_matrix_identity(s->m[s->depth]);
}

void glmt_glLoadMatrixf(const GLfloat *m)
{
    GLMT_CONTEXT();
    memcpy(current_matrix(c), m, 16 * sizeof(float));
}

void glmt_glLoadMatrixd(const GLdouble *m)
{
    GLMT_CONTEXT();
    float *top = current_matrix(c);
    for (int i = 0; i < 16; i++) top[i] = (float)m[i];
}

void glmt_glMultMatrixf(const GLfloat *m)
{
    GLMT_CONTEXT();
    multiply_current(c, m);
}

void glmt_glMultMatrixd(const GLdouble *m)
{
    GLMT_CONTEXT();
    float f[16];
    for (int i = 0; i < 16; i++) f[i] = (float)m[i];
    multiply_current(c, f);
}

void glmt_glPushMatrix(void)
{
    GLMT_CONTEXT();
    struct glmt_matrix_stack *s = current_stack(c);
    if (s->depth + 1 >= s->max)
    {
        glmt_set_error(c, GL_STACK_OVERFLOW);
        return;
    }
    memcpy(s->m[s->depth + 1], s->m[s->depth], 16 * sizeof(float));
    s->depth++;
}

void glmt_glPopMatrix(void)
{
    GLMT_CONTEXT();
    struct glmt_matrix_stack *s = current_stack(c);
    if (s->depth == 0)
    {
        glmt_set_error(c, GL_STACK_UNDERFLOW);
        return;
    }
    s->depth--;
}

void glmt_glOrtho(GLdouble left, GLdouble right, GLdouble bottom, GLdouble top, GLdouble zNear, GLdouble zFar)
{
    GLMT_CONTEXT();
    float m[16];
    if (left == right || bottom == top || zNear == zFar)
    {
        glmt_set_error(c, GL_INVALID_VALUE);
        return;
    }
    glmt_matrix_identity(m);
    m[0] = (float)(2.0 / (right - left));
    m[5] = (float)(2.0 / (top - bottom));
    m[10] = (float)(-2.0 / (zFar - zNear));
    m[12] = (float)(-(right + left) / (right - left));
    m[13] = (float)(-(top + bottom) / (top - bottom));
    m[14] = (float)(-(zFar + zNear) / (zFar - zNear));
    multiply_current(c, m);
}

void glmt_glFrustum(GLdouble left, GLdouble right, GLdouble bottom, GLdouble top, GLdouble zNear, GLdouble zFar)
{
    GLMT_CONTEXT();
    float m[16];
    if (left == right || bottom == top || zNear == zFar || zNear <= 0.0 || zFar <= 0.0)
    {
        glmt_set_error(c, GL_INVALID_VALUE);
        return;
    }
    memset(m, 0, sizeof(m));
    m[0] = (float)(2.0 * zNear / (right - left));
    m[5] = (float)(2.0 * zNear / (top - bottom));
    m[8] = (float)((right + left) / (right - left));
    m[9] = (float)((top + bottom) / (top - bottom));
    m[10] = (float)(-(zFar + zNear) / (zFar - zNear));
    m[11] = -1.0f;
    m[14] = (float)(-2.0 * zFar * zNear / (zFar - zNear));
    multiply_current(c, m);
}

void glmt_glTranslatef(GLfloat x, GLfloat y, GLfloat z)
{
    GLMT_CONTEXT();
    float m[16];
    glmt_matrix_identity(m);
    m[12] = x;
    m[13] = y;
    m[14] = z;
    multiply_current(c, m);
}

void glmt_glTranslated(GLdouble x, GLdouble y, GLdouble z) { glmt_glTranslatef((float)x, (float)y, (float)z); }

void glmt_glScalef(GLfloat x, GLfloat y, GLfloat z)
{
    GLMT_CONTEXT();
    float m[16];
    glmt_matrix_identity(m);
    m[0] = x;
    m[5] = y;
    m[10] = z;
    multiply_current(c, m);
}

void glmt_glScaled(GLdouble x, GLdouble y, GLdouble z) { glmt_glScalef((float)x, (float)y, (float)z); }

void glmt_glRotatef(GLfloat angle, GLfloat x, GLfloat y, GLfloat z)
{
    GLMT_CONTEXT();
    float m[16];
    double length = sqrt((double)x * x + (double)y * y + (double)z * z);
    double radians = (double)angle * 3.14159265358979323846 / 180.0;
    float s = (float)sin(radians), co = (float)cos(radians), t = 1.0f - co;

    if (length == 0.0) return;
    x = (float)(x / length);
    y = (float)(y / length);
    z = (float)(z / length);
    glmt_matrix_identity(m);
    m[0] = x * x * t + co;
    m[1] = y * x * t + z * s;
    m[2] = x * z * t - y * s;
    m[4] = x * y * t - z * s;
    m[5] = y * y * t + co;
    m[6] = y * z * t + x * s;
    m[8] = x * z * t + y * s;
    m[9] = y * z * t - x * s;
    m[10] = z * z * t + co;
    multiply_current(c, m);
}

void glmt_glRotated(GLdouble angle, GLdouble x, GLdouble y, GLdouble z)
{
    glmt_glRotatef((float)angle, (float)x, (float)y, (float)z);
}
