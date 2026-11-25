#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void *wispr_whisper_create(const char *model_path);
void wispr_whisper_destroy(void *engine);
char *wispr_whisper_transcribe(void *engine, const float *samples, int count,
                             const char *language, int threads, int word_timestamps, int *status);
int wispr_whisper_segment_count(void *engine);
const char *wispr_whisper_segment_text(void *engine, int index);
int64_t wispr_whisper_segment_start(void *engine, int index);
int64_t wispr_whisper_segment_end(void *engine, int index);
void wispr_string_free(char *text);
#ifdef __cplusplus
}
#endif
