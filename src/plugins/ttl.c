#define _GNU_SOURCE
#include "ttl.h"
#include "abi_lv2.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char *src;
    size_t pos;
    size_t len;
    TtlModel *m;
    char *base;
    char **pnames;
    char **piris;
    int np;
    int error;
} Parser;

TtlModel *ttl_model_new(void)
{
    return calloc(1, sizeof(TtlModel));
}

void ttl_model_free(TtlModel *m)
{
    if (!m) return;
    for (int i = 0; i < m->count; i++) {
        free(m->triples[i].s);
        free(m->triples[i].p);
        free(m->triples[i].o);
    }
    free(m->triples);
    for (int i = 0; i < m->n_loaded; i++) free(m->loaded[i]);
    free(m->loaded);
    free(m);
}

static void add_triple(TtlModel *m, const char *s, const char *p, const char *o, int literal)
{
    if (!s || !p || !o) return;
    if (m->count == m->capacity) {
        m->capacity = m->capacity ? m->capacity * 2 : 64;
        m->triples = realloc(m->triples, sizeof(TtlTriple) * m->capacity);
    }
    TtlTriple *t = &m->triples[m->count++];
    t->s = strdup(s);
    t->p = strdup(p);
    t->o = strdup(o);
    t->literal = literal;
}

static int eof(Parser *p)
{
    return p->pos >= p->len;
}

static char peek(Parser *p)
{
    return eof(p) ? 0 : p->src[p->pos];
}

static void skip_ws(Parser *p)
{
    while (!eof(p)) {
        char c = p->src[p->pos];
        if (c == '#') {
            while (!eof(p) && p->src[p->pos] != '\n') p->pos++;
        } else if (isspace((unsigned char) c)) {
            p->pos++;
        } else {
            break;
        }
    }
}

static int has_scheme(const char *iri)
{
    if (!isalpha((unsigned char) iri[0])) return 0;
    for (const char *c = iri; *c; c++) {
        if (*c == ':') return 1;
        if (!(isalnum((unsigned char) *c) || *c == '+' || *c == '-' || *c == '.')) return 0;
    }
    return 0;
}

static char *resolve(Parser *p, const char *iri)
{
    if (has_scheme(iri)) return strdup(iri);
    const char *base = p->base ? p->base : "";
    if (iri[0] == 0) return strdup(base);
    if (iri[0] == '#') {
        size_t bl = strcspn(base, "#");
        char *r = malloc(bl + strlen(iri) + 1);
        memcpy(r, base, bl);
        strcpy(r + bl, iri);
        return r;
    }
    if (iri[0] == '/') {
        char *r = malloc(strlen(iri) + 8);
        sprintf(r, "file://%s", iri);
        return r;
    }
    const char *slash = strrchr(base, '/');
    size_t dl = slash ? (size_t) (slash - base + 1) : 0;
    const char *rel = iri;
    while (rel[0] == '.' && rel[1] == '/') rel += 2;
    char *r = malloc(dl + strlen(rel) + 1);
    memcpy(r, base, dl);
    strcpy(r + dl, rel);
    return r;
}

static char *read_iri(Parser *p)
{
    p->pos++;
    size_t start = p->pos;
    while (!eof(p) && p->src[p->pos] != '>') p->pos++;
    if (eof(p)) {
        p->error = 1;
        return NULL;
    }
    char *raw = strndup(p->src + start, p->pos - start);
    p->pos++;
    char *r = resolve(p, raw);
    free(raw);
    return r;
}

static int is_name_stop(char c)
{
    return c == 0 || isspace((unsigned char) c) || strchr(";,[]()<>\"{}", c) != NULL;
}

static char *read_word(Parser *p)
{
    size_t start = p->pos;
    while (!eof(p) && !is_name_stop(p->src[p->pos])) p->pos++;
    size_t end = p->pos;
    while (end > start && p->src[end - 1] == '.') end--;
    p->pos = end;
    return strndup(p->src + start, end - start);
}

static char *expand(Parser *p, const char *word)
{
    const char *colon = strchr(word, ':');
    if (!colon) return strdup(word);
    size_t pl = colon - word;
    for (int i = p->np - 1; i >= 0; i--) {
        if (strlen(p->pnames[i]) == pl && strncmp(p->pnames[i], word, pl) == 0) {
            char *r = malloc(strlen(p->piris[i]) + strlen(colon + 1) + 1);
            strcpy(r, p->piris[i]);
            strcat(r, colon + 1);
            return r;
        }
    }
    return strdup(word);
}

static void add_prefix(Parser *p, const char *name, const char *iri)
{
    p->pnames = realloc(p->pnames, sizeof(char *) * (p->np + 1));
    p->piris = realloc(p->piris, sizeof(char *) * (p->np + 1));
    p->pnames[p->np] = strdup(name);
    p->piris[p->np] = strdup(iri);
    p->np++;
}

static char *new_blank(Parser *p)
{
    char buf[64];
    snprintf(buf, sizeof buf, "_:b%d", ++p->m->blank_counter);
    return strdup(buf);
}

static void append_utf8(char **out, size_t *len, size_t *cap, unsigned long cp)
{
    char tmp[4];
    int n;
    if (cp < 0x80) {
        tmp[0] = (char) cp;
        n = 1;
    } else if (cp < 0x800) {
        tmp[0] = (char) (0xC0 | (cp >> 6));
        tmp[1] = (char) (0x80 | (cp & 0x3F));
        n = 2;
    } else if (cp < 0x10000) {
        tmp[0] = (char) (0xE0 | (cp >> 12));
        tmp[1] = (char) (0x80 | ((cp >> 6) & 0x3F));
        tmp[2] = (char) (0x80 | (cp & 0x3F));
        n = 3;
    } else {
        tmp[0] = (char) (0xF0 | (cp >> 18));
        tmp[1] = (char) (0x80 | ((cp >> 12) & 0x3F));
        tmp[2] = (char) (0x80 | ((cp >> 6) & 0x3F));
        tmp[3] = (char) (0x80 | (cp & 0x3F));
        n = 4;
    }
    for (int i = 0; i < n; i++) {
        if (*len + 2 > *cap) {
            *cap = *cap * 2 + 16;
            *out = realloc(*out, *cap);
        }
        (*out)[(*len)++] = tmp[i];
    }
    (*out)[*len] = 0;
}

static char *read_string(Parser *p)
{
    char q = p->src[p->pos];
    int lng = p->pos + 2 < p->len && p->src[p->pos + 1] == q && p->src[p->pos + 2] == q;
    p->pos += lng ? 3 : 1;
    size_t cap = 64, len = 0;
    char *out = malloc(cap);
    out[0] = 0;
    while (!eof(p)) {
        char c = p->src[p->pos];
        if (lng) {
            if (c == q && p->pos + 2 < p->len && p->src[p->pos + 1] == q && p->src[p->pos + 2] == q) {
                p->pos += 3;
                return out;
            }
        } else if (c == q) {
            p->pos++;
            return out;
        }
        if (c == '\\' && p->pos + 1 < p->len) {
            char e = p->src[p->pos + 1];
            p->pos += 2;
            unsigned long cp = 0;
            switch (e) {
            case 'n': cp = '\n'; break;
            case 't': cp = '\t'; break;
            case 'r': cp = '\r'; break;
            case 'b': cp = '\b'; break;
            case 'f': cp = '\f'; break;
            case 'u':
            case 'U': {
                int digits = e == 'u' ? 4 : 8;
                char hex[9] = {0};
                for (int i = 0; i < digits && !eof(p); i++) hex[i] = p->src[p->pos++];
                cp = strtoul(hex, NULL, 16);
                break;
            }
            default: cp = (unsigned char) e; break;
            }
            append_utf8(&out, &len, &cap, cp);
            continue;
        }
        if (len + 2 > cap) {
            cap *= 2;
            out = realloc(out, cap);
        }
        out[len++] = c;
        out[len] = 0;
        p->pos++;
    }
    p->error = 1;
    return out;
}

static void parse_pol(Parser *p, const char *subject);

static char *parse_term(Parser *p, int *literal)
{
    *literal = 0;
    skip_ws(p);
    char c = peek(p);
    if (c == '<') return read_iri(p);
    if (c == '"' || c == '\'') {
        char *s = read_string(p);
        *literal = 1;
        if (peek(p) == '@') {
            p->pos++;
            while (!eof(p) && (isalnum((unsigned char) peek(p)) || peek(p) == '-')) p->pos++;
        } else if (peek(p) == '^' && p->pos + 1 < p->len && p->src[p->pos + 1] == '^') {
            p->pos += 2;
            if (peek(p) == '<') {
                free(read_iri(p));
            } else {
                free(read_word(p));
            }
        }
        return s;
    }
    if (c == '[') {
        p->pos++;
        char *b = new_blank(p);
        skip_ws(p);
        if (peek(p) != ']') parse_pol(p, b);
        skip_ws(p);
        if (peek(p) == ']') p->pos++;
        else p->error = 1;
        return b;
    }
    if (c == '(') {
        p->pos++;
        char *head = NULL;
        char *prev = NULL;
        for (;;) {
            skip_ws(p);
            if (eof(p) || p->error) break;
            if (peek(p) == ')') {
                p->pos++;
                break;
            }
            int lit;
            char *item = parse_term(p, &lit);
            if (!item) break;
            char *node = new_blank(p);
            add_triple(p->m, node, WAVE_RDF "first", item, lit);
            if (prev) {
                add_triple(p->m, prev, WAVE_RDF "rest", node, 0);
                free(prev);
            } else {
                head = strdup(node);
            }
            prev = node;
            free(item);
        }
        if (prev) {
            add_triple(p->m, prev, WAVE_RDF "rest", WAVE_RDF "nil", 0);
            free(prev);
        }
        return head ? head : strdup(WAVE_RDF "nil");
    }
    if (c == '_' && p->pos + 1 < p->len && p->src[p->pos + 1] == ':') {
        char *w = read_word(p);
        char *r = malloc(strlen(w) + 32);
        sprintf(r, "_:f%s", w + 2);
        free(w);
        return r;
    }
    if (isdigit((unsigned char) c) || c == '+' || c == '-' || (c == '.' && p->pos + 1 < p->len && isdigit((unsigned char) p->src[p->pos + 1]))) {
        size_t start = p->pos;
        p->pos++;
        while (!eof(p)) {
            char d = p->src[p->pos];
            if (isdigit((unsigned char) d) || d == 'e' || d == 'E' || d == '+' || d == '-') {
                p->pos++;
            } else if (d == '.' && p->pos + 1 < p->len && isdigit((unsigned char) p->src[p->pos + 1])) {
                p->pos++;
            } else {
                break;
            }
        }
        *literal = 1;
        return strndup(p->src + start, p->pos - start);
    }
    if (c == 0) {
        p->error = 1;
        return NULL;
    }
    char *w = read_word(p);
    if (w[0] == 0) {
        free(w);
        p->error = 1;
        if (!eof(p)) p->pos++;
        return NULL;
    }
    if (strcmp(w, "true") == 0 || strcmp(w, "false") == 0) {
        *literal = 1;
        return w;
    }
    char *r = expand(p, w);
    free(w);
    return r;
}

static void parse_pol(Parser *p, const char *subject)
{
    for (;;) {
        skip_ws(p);
        char c = peek(p);
        if (c == 0 || c == ']' || c == '.' || p->error) return;
        char *pred;
        if (c == 'a' && p->pos + 1 < p->len && is_name_stop(p->src[p->pos + 1])) {
            p->pos++;
            pred = strdup(WAVE_RDF "type");
        } else {
            int lit;
            pred = parse_term(p, &lit);
            if (!pred) return;
        }
        for (;;) {
            int lit;
            char *obj = parse_term(p, &lit);
            if (!obj) {
                free(pred);
                return;
            }
            add_triple(p->m, subject, pred, obj, lit);
            free(obj);
            skip_ws(p);
            if (peek(p) == ',') {
                p->pos++;
                continue;
            }
            break;
        }
        free(pred);
        skip_ws(p);
        if (peek(p) == ';') {
            while (peek(p) == ';') {
                p->pos++;
                skip_ws(p);
            }
            continue;
        }
        return;
    }
}

static int word_is(Parser *p, const char *w)
{
    size_t n = strlen(w);
    if (p->pos + n > p->len) return 0;
    if (strncasecmp(p->src + p->pos, w, n) != 0) return 0;
    return p->pos + n == p->len || isspace((unsigned char) p->src[p->pos + n]);
}

static void parse_document(Parser *p)
{
    while (!p->error) {
        skip_ws(p);
        if (eof(p)) return;
        int at = peek(p) == '@';
        if (word_is(p, "@prefix") || word_is(p, "prefix")) {
            p->pos += at ? 7 : 6;
            skip_ws(p);
            size_t start = p->pos;
            while (!eof(p) && p->src[p->pos] != ':') p->pos++;
            char *name = strndup(p->src + start, p->pos - start);
            p->pos++;
            skip_ws(p);
            char *iri = peek(p) == '<' ? read_iri(p) : NULL;
            if (iri) add_prefix(p, name, iri);
            free(name);
            free(iri);
            skip_ws(p);
            if (at && peek(p) == '.') p->pos++;
            continue;
        }
        if (word_is(p, "@base") || word_is(p, "base")) {
            p->pos += at ? 5 : 4;
            skip_ws(p);
            char *iri = peek(p) == '<' ? read_iri(p) : NULL;
            if (iri) {
                free(p->base);
                p->base = iri;
            }
            skip_ws(p);
            if (at && peek(p) == '.') p->pos++;
            continue;
        }
        int lit;
        char *subject = parse_term(p, &lit);
        if (!subject) return;
        skip_ws(p);
        if (peek(p) != '.') parse_pol(p, subject);
        free(subject);
        skip_ws(p);
        if (peek(p) == '.') {
            p->pos++;
        } else if (!eof(p)) {
            p->error = 1;
        }
    }
}

int ttl_parse_string(TtlModel *m, const char *text, const char *base_uri)
{
    Parser p = {0};
    p.src = text;
    p.len = strlen(text);
    p.m = m;
    p.base = strdup(base_uri ? base_uri : "");
    parse_document(&p);
    free(p.base);
    for (int i = 0; i < p.np; i++) {
        free(p.pnames[i]);
        free(p.piris[i]);
    }
    free(p.pnames);
    free(p.piris);
    return p.error ? -1 : 0;
}

char *ttl_path_to_uri(const char *path)
{
    size_t n = strlen(path);
    char *r = malloc(n * 3 + 8);
    strcpy(r, "file://");
    char *o = r + 7;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char) path[i];
        if (isalnum(c) || strchr("/-_.~+", c)) {
            *o++ = (char) c;
        } else {
            sprintf(o, "%%%02X", c);
            o += 3;
        }
    }
    *o = 0;
    return r;
}

char *ttl_uri_to_path(const char *uri)
{
    if (strncmp(uri, "file://", 7) != 0) return NULL;
    const char *s = uri + 7;
    if (strncmp(s, "localhost/", 10) == 0) s += 9;
    char *r = malloc(strlen(s) + 1);
    char *o = r;
    while (*s) {
        if (*s == '%' && isxdigit((unsigned char) s[1]) && isxdigit((unsigned char) s[2])) {
            char hex[3] = {s[1], s[2], 0};
            *o++ = (char) strtol(hex, NULL, 16);
            s += 3;
        } else {
            *o++ = *s++;
        }
    }
    *o = 0;
    return r;
}

int ttl_parse_file(TtlModel *m, const char *path)
{
    for (int i = 0; i < m->n_loaded; i++) {
        if (strcmp(m->loaded[i], path) == 0) return 0;
    }
    m->loaded = realloc(m->loaded, sizeof(char *) * (m->n_loaded + 1));
    m->loaded[m->n_loaded++] = strdup(path);
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0 || n > 64 * 1024 * 1024) {
        fclose(f);
        return -1;
    }
    char *text = malloc((size_t) n + 1);
    size_t got = fread(text, 1, (size_t) n, f);
    fclose(f);
    text[got] = 0;
    char *base = ttl_path_to_uri(path);
    int r = ttl_parse_string(m, text, base);
    free(base);
    free(text);
    return r;
}

const char *ttl_get(TtlModel *m, const char *s, const char *p)
{
    for (int i = 0; i < m->count; i++) {
        if (strcmp(m->triples[i].s, s) == 0 && strcmp(m->triples[i].p, p) == 0) return m->triples[i].o;
    }
    return NULL;
}

int ttl_get_all(TtlModel *m, const char *s, const char *p, const char **out, int max)
{
    int n = 0;
    for (int i = 0; i < m->count && n < max; i++) {
        if (strcmp(m->triples[i].s, s) == 0 && strcmp(m->triples[i].p, p) == 0) out[n++] = m->triples[i].o;
    }
    return n;
}

int ttl_has(TtlModel *m, const char *s, const char *p, const char *o)
{
    for (int i = 0; i < m->count; i++) {
        if (strcmp(m->triples[i].s, s) == 0 && strcmp(m->triples[i].p, p) == 0 && strcmp(m->triples[i].o, o) == 0) return 1;
    }
    return 0;
}

int ttl_subjects(TtlModel *m, const char *p, const char *o, const char **out, int max)
{
    int n = 0;
    for (int i = 0; i < m->count && n < max; i++) {
        if (strcmp(m->triples[i].p, p) == 0 && strcmp(m->triples[i].o, o) == 0) {
            int dup = 0;
            for (int j = 0; j < n; j++) {
                if (strcmp(out[j], m->triples[i].s) == 0) dup = 1;
            }
            if (!dup) out[n++] = m->triples[i].s;
        }
    }
    return n;
}
