#ifndef RT_STORE_ENGINE_H
#define RT_STORE_ENGINE_H
#ifdef __cplusplus
extern "C" {
#endif
char *rt_store_request(const char *json);
char *rt_store_progress(void);
void rt_store_cancel(void);
void rt_store_free(char *value);
#ifdef __cplusplus
}
#endif
#endif
