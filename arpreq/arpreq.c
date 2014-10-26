#include <Python.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <errno.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>

static PyObject *Error = NULL;

void set_verror(PyObject * exc, const char *format, va_list args) {
    char * msg;
    if (vasprintf(&msg, format, args) == -1) {
        PyErr_NoMemory();
        return;
    }
    PyErr_SetString(exc, msg);
    free(msg);
}

void set_error(PyObject * exc, const char* format, ...) {
    va_list args;
    va_start(args, format);
    set_verror(exc, format, args);
    va_end(args);
}

static PyObject *
arpreq(PyObject * self, PyObject * args) {
    const char * addr_str;
    if (!PyArg_ParseTuple(args, "s", &addr_str)) {
        return NULL;
    }

    struct arpreq arpreq;
    memset(&arpreq, 0, sizeof(arpreq));

    struct sockaddr_in *sin = (struct sockaddr_in *) &arpreq.arp_pa;
    sin->sin_family = AF_INET;
    if (inet_pton(AF_INET, addr_str, &(sin->sin_addr)) != 1) {
        set_error(PyExc_ValueError, "Invalid address %s\n", addr_str);
        return NULL;
    }
    int addr = sin->sin_addr.s_addr;

    struct ifaddrs * head_ifa;
    if (getifaddrs(&head_ifa) != 0) {
        set_error(Error, "getifaddrs: %s\n", strerror(errno));
        return NULL;
    }

    for (struct ifaddrs * ifa = head_ifa; ifa; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL)
            continue;
        if (ifa->ifa_addr->sa_family != AF_INET)
            continue;
        if (ifa->ifa_flags & IFF_POINTOPOINT)
            continue;
        int ifaddr = ((struct sockaddr_in *) ifa->ifa_addr)->sin_addr.s_addr;
        int netmask = ((struct sockaddr_in *) ifa->ifa_netmask)->sin_addr.s_addr;
        if ((ifaddr & netmask) == (addr & netmask)) {
            strncpy(arpreq.arp_dev, ifa->ifa_name, sizeof(arpreq.arp_dev));
            break;
        }
    }
    freeifaddrs(head_ifa);
    if (arpreq.arp_dev[0] == 0) {
        set_error(Error, "Requested address is not available on any local subnet.\n");
        return NULL;
    }

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s == -1) {
        set_error(Error, "socket failed: %s (%d)\n: %s\n", strerror(errno), errno);
        return NULL;
    }

    PyObject * rv;
    if (ioctl(s, SIOCGARP, &arpreq) < 0) {
        rv = Py_None;
        goto cleanup;
    }

    if (arpreq.arp_flags & ATF_COM) {
        unsigned char *eap = (unsigned char *) &arpreq.arp_ha.sa_data[0];
        char mac[18];
        snprintf(mac, sizeof(mac), "%02x:%02x:%02x:%02x:%02x:%02x\n",
                 eap[0], eap[1], eap[2], eap[3], eap[4], eap[5]);
        rv = Py_BuildValue("s", mac);
    } else {
        rv = Py_None;
    }

cleanup:
    if (close(s) == -1) {
        set_error(PyExc_Exception, "close: %s (%d)\n", strerror(errno), errno);
        return NULL;
    }
    Py_INCREF(rv);
    return rv;
}

static PyMethodDef methods[] = {
    {"arpreq", arpreq, METH_VARARGS, "Probe the kernel ARP cache for the MAC address of an IPv4 address."},
    {NULL, NULL, 0, NULL}
};

PyMODINIT_FUNC
initarpreq(void) {
    PyObject * m;
    m = Py_InitModule("arpreq", methods);
    if (m == NULL)
        return;

    Error = PyErr_NewException("arpreq.Error", NULL, NULL);
    Py_INCREF(Error);
    PyModule_AddObject(m, "Error", Error);
}


