#ifndef HEADER_MIPKIH
#define HEADER_MIPKIH
#include <stdint.h>

typedef struct {
  const char *cert_file;
  const char *key_file;
  int is_universal;
} mipki_config_entry;

typedef enum {
  MIPKI_SIGN,
  MIPKI_VERIFY
} mipki_mode;

typedef struct mipki_state mipki_state;
typedef uint16_t mipki_signature;
typedef const void* mipki_chain;

// A callback used to ask for the passphrase of the private key
typedef int (*password_callback)(char *pass, int max_size, const char *key_file);

mipki_state *mipki_init(const mipki_config_entry config[], size_t config_len, password_callback pcb, int *erridx);
void mipki_free(mipki_state *st);

int mipki_add_root_file_or_path(mipki_state *st, const char *ca_file);
mipki_chain mipki_select_certificate(mipki_state *st, const char *sni, const mipki_signature *algs, size_t algs_len, mipki_signature *selected);
int mipki_sign_verify(mipki_state *st, mipki_chain cert_ptr, const mipki_signature sigalg, const char *tbs, size_t tbs_len, char *sig, size_t *sig_len, mipki_mode m);
mipki_chain mipki_parse_chain(mipki_state *st, const char *chain, size_t chain_len);
size_t mipki_format_chain(mipki_state *st, mipki_chain chain, char *buffer, size_t buffer_len);
int mipki_validate_chain(mipki_state *st, mipki_chain chain, const char *host);
void mipki_free_chain(mipki_state *st, mipki_chain chain);

#endif
