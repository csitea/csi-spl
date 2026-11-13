#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <stdlib.h>
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e9+t.tv_nsec;}
int main(int c,char**v){
  long N=2000000; double t=now();
  for(long i=0;i<N;i++) syscall(SYS_getppid);
  double d=now()-t; struct rusage r; getrusage(RUSAGE_SELF,&r);
  printf("getppid: %.0f ns/call wall (n=%ld) sys=%.2fs usr=%.2fs\n", d/N, N, r.ru_stime.tv_sec+r.ru_stime.tv_usec/1e6, r.ru_utime.tv_sec+r.ru_utime.tv_usec/1e6);
  int M=2000; t=now();
  for(int i=0;i<M;i++){ pid_t p=fork(); if(!p) _exit(0); waitpid(p,0,0);}  d=now()-t;
  printf("fork+exit+wait: %.1f us/iter wall (n=%d)\n", d/M/1000, M);
  t=now();
  for(int i=0;i<M;i++){ pid_t p=vfork(); if(!p){execl("/bin/true","true",(char*)0);_exit(127);} waitpid(p,0,0);} d=now()-t;
  struct rusage rc; getrusage(RUSAGE_CHILDREN,&rc);
  printf("vfork+exec(/bin/true)+wait: %.1f us/iter wall (n=%d)\n", d/M/1000, M);
  return 0;}
