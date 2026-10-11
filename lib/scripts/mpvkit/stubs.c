// Inert stubs. These two symbols come from Samba's generated NDR tables inside
// MPVKit's Libsmbclient; they are only reachable through smb:///nfs:// code paths
// that media_kit never touches. Stubbing them keeps the link strict (any *real*
// missing symbol still fails loudly) instead of falling back to dynamic_lookup.

void ndr_table_register_builtin_tables(void) {}

char ndr_table_nfs4acl_interface[512] = {0};
