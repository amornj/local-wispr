#include "WhisperBridge.h"
#include "whisper.h"
#include <cstdlib>
#include <cstring>
#include <string>

void *wispr_whisper_create(const char *model_path) {
    whisper_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
    auto params = whisper_context_default_params();
    params.use_gpu = false; // This build also works on Intel iMacs.
    return whisper_init_from_file_with_params(model_path, params);
}

void wispr_whisper_destroy(void *engine) {
    if (engine) whisper_free(static_cast<whisper_context *>(engine));
}

char *wispr_whisper_transcribe(void *engine, const float *samples, int count,
                             const char *language, int threads, int word_timestamps, int *status) {
    auto *context = static_cast<whisper_context *>(engine);
    auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = threads;
    params.language = language;
    params.translate = false;
    params.no_context = true;
    params.no_timestamps = !word_timestamps;
    params.token_timestamps = word_timestamps;
    params.max_len = word_timestamps ? 1 : 0;
    params.split_on_word = word_timestamps;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.suppress_blank = true;
    params.suppress_nst = true;
    params.temperature = 0;
    params.temperature_inc = 0;
    params.greedy.best_of = 1;
    *status = whisper_full(context, params, samples, count);
    if (*status != 0) return nullptr;
    std::string result;
    for (int i = 0; i < whisper_full_n_segments(context); ++i) {
        if (whisper_full_get_segment_no_speech_prob(context, i) < 0.75f)
            result += whisper_full_get_segment_text(context, i);
    }
    return strdup(result.c_str());
}

int wispr_whisper_segment_count(void *engine) {
    return whisper_full_n_segments(static_cast<whisper_context *>(engine));
}

const char *wispr_whisper_segment_text(void *engine, int index) {
    auto *context = static_cast<whisper_context *>(engine);
    if (index < 0 || index >= whisper_full_n_segments(context)) return "";
    if (whisper_full_get_segment_no_speech_prob(context, index) >= 0.75f) return "";
    return whisper_full_get_segment_text(context, index);
}

int64_t wispr_whisper_segment_start(void *engine, int index) {
    return whisper_full_get_segment_t0(static_cast<whisper_context *>(engine), index);
}

int64_t wispr_whisper_segment_end(void *engine, int index) {
    return whisper_full_get_segment_t1(static_cast<whisper_context *>(engine), index);
}

void wispr_string_free(char *text) { free(text); }
