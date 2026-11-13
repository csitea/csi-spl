#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/wait.h>
static double tv(struct timeval a){return a.tv_sec*1e6+a.tv_usec;}
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e6+t.tv_nsec/1e3;}
int main(){ int M=3000; struct rusage s0,s1,c0,c1;
 getrusage(RUSAGE_SELF,&s0); getrusage(RUSAGE_CHILDREN,&c0); double t=now();
 for(int i=0;i<M;i++){ pid_t p=fork(); if(!p) _exit(0); waitpid(p,0,0);}
 double w=now()-t; getrusage(RUSAGE_SELF,&s1); getrusage(RUSAGE_CHILDREN,&c1);
 printf("fork: wall %.0f us/it; parent sys %.0f us/it; child sys %.0f us/it; child usr %.0f\n", w/M, (tv(s1.ru_stime)-tv(s0.ru_stime))/M, (tv(c1.ru_stime)-tv(c0.ru_stime))/M,(tv(c1.ru_utime)-tv(c0.ru_utime))/M);
 getrusage(RUSAGE_SELF,&s0); getrusage(RUSAGE_CHILDREN,&c0); t=now();
 for(int i=0;i<M;i++){ pid_t p=vfork(); if(!p){execl("/bin/true","true",(char*)0);_exit(127);} waitpid(p,0,0);}
 w=now()-t; getrusage(RUSAGE_SELF,&s1); getrusage(RUSAGE_CHILDREN,&c1);
 printf("vfork+exec true: wall %.0f us/it; parent sys %.0f; child sys %.0f; child usr %.0f\n", w/M, (tv(s1.ru_stime)-tv(s0.ru_stime))/M, (tv(c1.ru_stime)-tv(c0.ru_stime))/M,(tv(c1.ru_utime)-tv(c0.ru_utime))/M);
}
