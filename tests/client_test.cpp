// client_test.cpp - small scriptable snap7 client for tests/rogue_plc.py.
//
// Loads snap7.dll from the directory of the exe (LoadLibrary), calls the Cli_* C API
// against 127.0.0.1:<port> and prints one line per call with the result code in hex.
//
//   client_test.exe <port> [op ...]
//   ops: connect | read:<bytes> | write:<bytes> | cpuinfo | status
//   default: connect read:100 write:100 cpuinfo status
//
// Buffers are allocated with the exact requested size so that AddressSanitizer
// reports any write or read beyond them.
#include "snap7.h"   // first: it selects the 32 bit time_t the library uses
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef S7Object (S7API *pCreate)();
typedef void (S7API *pDestroy)(S7Object *);
typedef int (S7API *pConnectTo)(S7Object, const char *, int, int);
typedef int (S7API *pSetParam)(S7Object, int, void *);
typedef int (S7API *pReadArea)(S7Object, int, int, int, int, int, void *);
typedef int (S7API *pWriteArea)(S7Object, int, int, int, int, int, void *);
typedef int (S7API *pGetCpuInfo)(S7Object, TS7CpuInfo *);
typedef int (S7API *pGetPlcStatus)(S7Object, int *);
typedef int (S7API *pDisconnect)(S7Object);

template <class T> static T Sym(HMODULE h, const char *name)
{
    T p = (T)GetProcAddress(h, name);
    if (!p) { printf("missing export %s\n", name); exit(2); }
    return p;
}

int main(int argc, char **argv)
{
    if (argc < 2) { printf("usage: client_test <port> [connect|read:N|write:N|cpuinfo|status ...]\n"); return 2; }
    unsigned short port = (unsigned short)atoi(argv[1]);

    HMODULE h = LoadLibraryA("snap7.dll");
    if (!h) { printf("cannot load snap7.dll (error %lu)\n", GetLastError()); return 2; }
    pCreate Create = Sym<pCreate>(h, "Cli_Create");
    pDestroy Destroy = Sym<pDestroy>(h, "Cli_Destroy");
    pConnectTo ConnectTo = Sym<pConnectTo>(h, "Cli_ConnectTo");
    pSetParam SetParam = Sym<pSetParam>(h, "Cli_SetParam");
    pReadArea ReadArea = Sym<pReadArea>(h, "Cli_ReadArea");
    pWriteArea WriteArea = Sym<pWriteArea>(h, "Cli_WriteArea");
    pGetCpuInfo GetCpuInfo = Sym<pGetCpuInfo>(h, "Cli_GetCpuInfo");
    pGetPlcStatus GetPlcStatus = Sym<pGetPlcStatus>(h, "Cli_GetPlcStatus");
    pDisconnect Disconnect = Sym<pDisconnect>(h, "Cli_Disconnect");

    S7Object client = Create();
    SetParam(client, p_u16_RemotePort, &port);
    int timeout = 3000;   // ms, so that a hanging scenario ends
    SetParam(client, p_i32_RecvTimeout, &timeout);

    const char *defOps[] = { "connect", "read:100", "write:100", "cpuinfo", "status" };
    int nOps = argc > 2 ? argc - 2 : 5;
    for (int i = 0; i < nOps; i++)
    {
        const char *op = argc > 2 ? argv[2 + i] : defOps[i];
        int rc;
        if (strcmp(op, "connect") == 0)
        {
            rc = ConnectTo(client, "127.0.0.1", 0, 2);
            printf("ConnectTo      rc=0x%08X\n", (unsigned)rc);
        }
        else if (strncmp(op, "read:", 5) == 0)
        {
            int n = atoi(op + 5);
            unsigned char *buf = (unsigned char *)malloc(n);   // exact size on purpose
            memset(buf, 0xEE, n);
            rc = ReadArea(client, S7AreaDB, 1, 0, n, S7WLByte, buf);
            bool ok = (rc == 0);
            for (int k = 0; ok && k < n; k++)
                ok = (buf[k] == (unsigned char)k);
            printf("ReadArea(%d)  rc=0x%08X data=%s\n", n, (unsigned)rc, rc ? "-" : (ok ? "ok" : "MISMATCH"));
            free(buf);
        }
        else if (strncmp(op, "write:", 6) == 0)
        {
            int n = atoi(op + 6);
            unsigned char *buf = (unsigned char *)malloc(n);
            memset(buf, 0x5A, n);
            rc = WriteArea(client, S7AreaDB, 1, 0, n, S7WLByte, buf);
            printf("WriteArea(%d) rc=0x%08X\n", n, (unsigned)rc);
            free(buf);
        }
        else if (strcmp(op, "cpuinfo") == 0)
        {
            TS7CpuInfo info;
            rc = GetCpuInfo(client, &info);
            printf("GetCpuInfo     rc=0x%08X name=%s\n", (unsigned)rc, rc ? "-" : info.ModuleTypeName);
        }
        else if (strcmp(op, "status") == 0)
        {
            int status = -1;
            rc = GetPlcStatus(client, &status);
            printf("PlcStatus      rc=0x%08X status=%d\n", (unsigned)rc, status);
        }
        else
        {
            printf("unknown op %s\n", op);
            return 2;
        }
        fflush(stdout);
    }
    Disconnect(client);
    Destroy(&client);
    printf("done\n");
    return 0;
}
