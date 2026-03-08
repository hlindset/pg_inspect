#include <erl_nif.h>
#include <stdint.h>

ERL_NIF_TERM pginspect_make_uint64(ErlNifEnv *env, uint64_t value) {
  return enif_make_uint64(env, value);
}
