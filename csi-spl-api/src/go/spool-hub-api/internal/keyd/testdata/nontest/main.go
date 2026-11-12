// Command nontest is a plain (non-test) binary for testhook_test.go: it asks
// keyd for the test scrypt cost, then seals a bundle into the dir given as
// its argument and prints whether the call was taken.
package main

import (
	"fmt"
	"os"

	"github.com/csitea/csi-spl/spool-hub-api/internal/keyd"
)

func main() {
	took := keyd.SetTestScryptWorkFactor(14)
	key, err := keyd.NewUnlockKey()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if _, err := keyd.InitAgent(os.Args[1], os.Args[2], "c-101", key); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("took=%v\n", took)
}
