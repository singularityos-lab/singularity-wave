#ifndef WAVE_TTL_H
#define WAVE_TTL_H

typedef struct {
    char *s;
    char *p;
    char *o;
    int literal;
} TtlTriple;

typedef struct {
    TtlTriple *triples;
    int count;
    int capacity;
    int blank_counter;
    char **loaded;
    int n_loaded;
} TtlModel;

TtlModel *ttl_model_new(void);
void ttl_model_free(TtlModel *m);
int ttl_parse_file(TtlModel *m, const char *path);
int ttl_parse_string(TtlModel *m, const char *text, const char *base_uri);
const char *ttl_get(TtlModel *m, const char *s, const char *p);
int ttl_get_all(TtlModel *m, const char *s, const char *p, const char **out, int max);
int ttl_has(TtlModel *m, const char *s, const char *p, const char *o);
int ttl_subjects(TtlModel *m, const char *p, const char *o, const char **out, int max);
char *ttl_path_to_uri(const char *path);
char *ttl_uri_to_path(const char *uri);

#endif
