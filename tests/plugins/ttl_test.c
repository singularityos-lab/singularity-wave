#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ttl.h"

static int failures = 0;

static void check(int ok, const char *name)
{
    printf("%s %s\n", ok ? "ok" : "FAIL", name);
    if (!ok) failures++;
}

static char *nested(char open, int depth)
{
    char *s = malloc((size_t) depth * 5 + 16);
    size_t o = 0;
    memcpy(s, "<a> <b> ", 8);
    o = 8;
    for (int i = 0; i < depth; i++) {
        if (open == '[') {
            memcpy(s + o, "[<p> ", 5);
            o += 5;
        } else {
            s[o++] = '(';
        }
    }
    s[o] = 0;
    return s;
}

int main(void)
{
    TtlModel *m = ttl_model_new();
    int r = ttl_parse_string(m, "@prefix lv2: <http://lv2plug.in/ns/lv2core#> .\n<x> a lv2:Plugin ; lv2:port [ lv2:index 0 ; lv2:symbol \"in\" ] .\n", "file:///b/");
    check(r == 0 && ttl_has(m, "file:///b/x", "http://www.w3.org/1999/02/22-rdf-syntax-ns#type", "http://lv2plug.in/ns/lv2core#Plugin"), "plain document parses");
    check(r == 0 && m->count == 4, "plain document triples");
    ttl_model_free(m);

    const char opens[] = {'[', '('};
    for (int i = 0; i < 2; i++) {
        char *s = nested(opens[i], 200000);
        m = ttl_model_new();
        r = ttl_parse_string(m, s, "file:///b/");
        check(r == -1, opens[i] == '[' ? "deep blank nodes rejected" : "deep lists rejected");
        ttl_model_free(m);
        free(s);
    }

    m = ttl_model_new();
    r = ttl_parse_string(m, "<a> <b> ( ( ( <c> ) ) ) .", "file:///b/");
    check(r == 0, "shallow nesting still parses");
    ttl_model_free(m);

    printf("%d failures\n", failures);
    return failures ? 1 : 0;
}
