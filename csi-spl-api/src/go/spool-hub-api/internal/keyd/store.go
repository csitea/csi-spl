package keyd

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"filippo.io/age"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

// scryptLogN is age's default work factor (about a second). Tests in this
// package lower it; a production binary never does.
var scryptLogN = 18

var uuidRe = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// AgentKey is one agent identity. Identity is the age secret and never goes
// to disk in clear: the store seals it inside agents.age.
type AgentKey struct {
	ID       string `json:"id"`
	Identity string `json:"identity"`
	Created  string `json:"created"`
}

type diskBundle struct {
	V      int        `json:"v"`
	Agents []AgentKey `json:"agents"`
}

type ownerFile struct {
	V        int    `json:"v"`
	Identity string `json:"identity"`
}

// StateDir is SPOOL_ENC_STATE, or $HOME/.spool/enc when that is unset.
func StateDir() (string, error) {
	if d := os.Getenv("SPOOL_ENC_STATE"); d != "" {
		if !filepath.IsAbs(d) {
			return "", errors.New("SPOOL_ENC_STATE must be absolute")
		}
		return d, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", errors.New("cannot resolve the key state directory")
	}
	return filepath.Join(home, ".spool", "enc"), nil
}

// ValidWorkspace reports whether id is a uuid. The workspace is named by its
// id, never by a display name.
func ValidWorkspace(id string) bool { return uuidRe.MatchString(id) }

// WorkspaceOf reads the workspace id stored in clear beside the keys.
func WorkspaceOf(dir string) (string, error) {
	b, err := os.ReadFile(filepath.Join(dir, "keys", "workspace"))
	if err != nil {
		return "", errors.New("workspace is not initialised")
	}
	ws := strings.TrimSpace(string(b))
	if !ValidWorkspace(ws) {
		return "", errors.New("workspace id is not a uuid")
	}
	return ws, nil
}

// InitAgent creates the agent's identity, or adds it to the sealed bundle.
// The recipient (public key) is written beside the bundle for the seats.
func InitAgent(dir, workspace, id string, pass []byte) (string, error) {
	if !agentid.IsNew(id) {
		return "", errors.New("agent id is not valid")
	}
	if err := mkdirState(dir); err != nil {
		return "", err
	}
	if err := bindWorkspace(dir, workspace); err != nil {
		return "", err
	}
	ident, err := age.GenerateX25519Identity()
	if err != nil {
		return "", err
	}
	pub := ident.Recipient().String()
	var b diskBundle
	if _, statErr := os.Stat(agentsPath(dir)); statErr == nil {
		loaded, err := loadDisk(dir, pass)
		if err != nil {
			return "", err
		}
		b = loaded
		for _, a := range b.Agents {
			if a.ID == id {
				return "", errors.New("identity already exists")
			}
		}
	} else if !os.IsNotExist(statErr) {
		return "", errors.New("could not open the agent keys")
	}
	b.V = 1
	b.Agents = append(b.Agents, AgentKey{
		ID: id, Identity: ident.String(), Created: time.Now().UTC().Format(time.RFC3339),
	})
	if err := saveDisk(dir, b, pass); err != nil {
		return "", err
	}
	if err := writePub(dir, id, pub); err != nil {
		return "", err
	}
	return pub, nil
}

// InitOwner creates the owner's identity under its own passphrase.
// The secret file is owner.age; it is not put in the agent bundle.
// The caller moves that file off the box. This function does not print a path.
func InitOwner(dir, workspace string, pass []byte) (string, error) {
	if err := mkdirState(dir); err != nil {
		return "", err
	}
	if err := bindWorkspace(dir, workspace); err != nil {
		return "", err
	}
	if _, err := os.Stat(filepath.Join(dir, "keys", "owner.age")); err == nil {
		return "", errors.New("owner key already exists")
	}
	ident, err := age.GenerateX25519Identity()
	if err != nil {
		return "", err
	}
	body, err := json.Marshal(ownerFile{V: 1, Identity: ident.String()})
	if err != nil {
		return "", err
	}
	defer Wipe(body)
	if err := writeScrypt(filepath.Join(dir, "keys", "owner.age"), body, pass, 0600); err != nil {
		return "", err
	}
	pub := ident.Recipient().String()
	if err := writePub(dir, "owner", pub); err != nil {
		return "", err
	}
	return pub, nil
}

// Rotate appends a new identity for id and leaves the old one in the bundle,
// so messages sealed to the old recipient still open. The public file becomes
// the new recipient.
func Rotate(dir, id string, pass []byte) (string, error) {
	if !agentid.IsNew(id) {
		return "", errors.New("agent id is not valid")
	}
	b, err := loadDisk(dir, pass)
	if err != nil {
		return "", err
	}
	found := false
	for _, a := range b.Agents {
		if a.ID == id {
			found = true
			break
		}
	}
	if !found {
		return "", errors.New("no identity for that agent")
	}
	ident, err := age.GenerateX25519Identity()
	if err != nil {
		return "", err
	}
	pub := ident.Recipient().String()
	b.Agents = append(b.Agents, AgentKey{
		ID: id, Identity: ident.String(), Created: time.Now().UTC().Format(time.RFC3339),
	})
	if err := saveDisk(dir, b, pass); err != nil {
		return "", err
	}
	if err := writePub(dir, id, pub); err != nil {
		return "", err
	}
	return pub, nil
}

// LoadAgents opens the bundle. The slice is newest identity first.
func LoadAgents(dir string, pass []byte) ([]AgentKey, error) {
	b, err := loadDisk(dir, pass)
	if err != nil {
		return nil, err
	}
	out := make([]AgentKey, len(b.Agents))
	for i := range b.Agents {
		out[len(out)-1-i] = b.Agents[i]
	}
	return out, nil
}

func mkdirState(dir string) error {
	keys := filepath.Join(dir, "keys")
	if err := os.MkdirAll(keys, 0700); err != nil {
		return errors.New("could not create the key state")
	}
	if err := os.Chmod(dir, 0700); err != nil {
		return errors.New("could not create the key state")
	}
	if err := os.Chmod(keys, 0700); err != nil {
		return errors.New("could not create the key state")
	}
	return nil
}

func bindWorkspace(dir, workspace string) error {
	if !ValidWorkspace(workspace) {
		return errors.New("workspace id is not a uuid")
	}
	cur, err := WorkspaceOf(dir)
	if err == nil {
		if cur != workspace {
			return errors.New("workspace mismatch")
		}
		return nil
	}
	path := filepath.Join(dir, "keys", "workspace")
	if err := os.WriteFile(path, []byte(workspace+"\n"), 0644); err != nil {
		return errors.New("could not store the workspace id")
	}
	return os.Chmod(path, 0644)
}

func writePub(dir, name, pub string) error {
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
		return errors.New("bad key name")
	}
	path := filepath.Join(dir, "keys", name+".pub")
	if err := os.WriteFile(path, []byte(pub+"\n"), 0644); err != nil {
		return errors.New("could not store the recipient")
	}
	return os.Chmod(path, 0644)
}

func agentsPath(dir string) string { return filepath.Join(dir, "keys", "agents.age") }

func loadDisk(dir string, pass []byte) (diskBundle, error) {
	plain, err := openScrypt(agentsPath(dir), pass)
	if err != nil {
		return diskBundle{}, err
	}
	defer Wipe(plain)
	var b diskBundle
	if err := json.Unmarshal(plain, &b); err != nil || b.V != 1 {
		return diskBundle{}, errors.New("could not open the agent keys")
	}
	return b, nil
}

func saveDisk(dir string, b diskBundle, pass []byte) error {
	plain, err := json.Marshal(b)
	if err != nil {
		return errors.New("could not seal the agent keys")
	}
	defer Wipe(plain)
	return writeScrypt(agentsPath(dir), plain, pass, 0600)
}

func writeScrypt(path string, plain, pass []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".w-*")
	if err != nil {
		return errors.New("could not seal the agent keys")
	}
	tmpName := tmp.Name()
	keep := false
	defer func() {
		if !keep {
			os.Remove(tmpName)
		}
	}()
	if err := os.Chmod(tmpName, 0600); err != nil {
		tmp.Close()
		return errors.New("could not seal the agent keys")
	}
	if err := sealScrypt(tmp, plain, pass); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return errors.New("could not seal the agent keys")
	}
	if err := os.Chmod(tmpName, mode); err != nil {
		return errors.New("could not seal the agent keys")
	}
	if err := os.Rename(tmpName, path); err != nil {
		return errors.New("could not seal the agent keys")
	}
	keep = true
	return os.Chmod(path, mode)
}

// sealScrypt writes plain to w, sealed with age's scrypt mode under pass.
func sealScrypt(w io.Writer, plain, pass []byte) error {
	rec, err := age.NewScryptRecipient(string(pass))
	if err != nil {
		return errors.New("could not seal the agent keys")
	}
	rec.SetWorkFactor(scryptLogN)
	enc, err := age.Encrypt(w, rec)
	if err != nil {
		return errors.New("could not seal the agent keys")
	}
	if _, err := enc.Write(plain); err != nil {
		enc.Close()
		return errors.New("could not seal the agent keys")
	}
	if err := enc.Close(); err != nil {
		return errors.New("could not seal the agent keys")
	}
	return nil
}

func openScrypt(path string, pass []byte) ([]byte, error) {
	id, err := age.NewScryptIdentity(string(pass))
	if err != nil {
		return nil, errors.New("could not open the agent keys")
	}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, errors.New("agent keys are not initialised")
		}
		return nil, errors.New("could not open the agent keys")
	}
	defer f.Close()
	r, err := age.Decrypt(f, id)
	if err != nil {
		return nil, errors.New("could not open the agent keys")
	}
	plain, err := io.ReadAll(io.LimitReader(r, 1<<20))
	if err != nil {
		Wipe(plain)
		return nil, errors.New("could not open the agent keys")
	}
	return plain, nil
}

// UnlockKeyPath is the unattended key file of the workspace (spec 136
// section 4, Q7 B): <state>/keys/unlock.key, mode 0400.
func UnlockKeyPath(dir string) string { return filepath.Join(dir, "keys", "unlock.key") }

// NewUnlockKey makes a key file secret: 32 random bytes, base64, 44 chars.
func NewUnlockKey() ([]byte, error) {
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return nil, errors.New("could not make a key")
	}
	out := make([]byte, base64.StdEncoding.EncodedLen(len(raw)))
	base64.StdEncoding.Encode(out, raw[:])
	Wipe(raw[:])
	return out, nil
}

// rekeyStep is called after each durable step of a rekey. Tests make it
// fail to leave the files exactly as a crash at that point would.
var rekeyStep = func(string) error { return nil }

// RotateUnlockKey seals the agent keys under a fresh key file secret. The
// held identities do not change, so a running keyd keeps serving.
func RotateUnlockKey(dir, keyPath string) error {
	if err := RecoverUnlockKey(dir, keyPath); err != nil {
		return err
	}
	old, err := ReadKeyFile(keyPath)
	if err != nil {
		return err
	}
	defer Wipe(old)
	return RekeyToFile(dir, old, keyPath)
}

// RekeyToFile moves the agent keys from pass (typed or an older key file)
// to a new generated key file at keyPath.
func RekeyToFile(dir string, pass []byte, keyPath string) error {
	if err := RecoverUnlockKey(dir, keyPath); err != nil {
		return err
	}
	b, err := loadDisk(dir, pass)
	if err != nil {
		return err
	}
	defer WipeAgents(b.Agents)
	next, err := NewUnlockKey()
	if err != nil {
		return err
	}
	defer Wipe(next)
	return commitRekey(dir, b, next, keyPath)
}

// RekeyToPass moves the agent keys from pass to a typed passphrase next.
func RekeyToPass(dir string, pass, next []byte) error {
	b, err := loadDisk(dir, pass)
	if err != nil {
		return err
	}
	defer WipeAgents(b.Agents)
	return commitRekey(dir, b, next, "")
}

// commitRekey is the crash-safe write of spec 136 section 4: agents.age.tmp
// and <key>.tmp, fsync, then rename the bundle before the key. keyPath ""
// means the new secret is typed and no key file is written.
func commitRekey(dir string, b diskBundle, next []byte, keyPath string) error {
	plain, err := json.Marshal(b)
	if err != nil {
		return errors.New("could not seal the agent keys")
	}
	defer Wipe(plain)
	agentsTmp := agentsPath(dir) + ".tmp"
	if err := writeNew(agentsTmp, 0600, func(f *os.File) error { return sealScrypt(f, plain, next) }); err != nil {
		return err
	}
	if err := rekeyStep("agents-tmp"); err != nil {
		return err
	}
	if keyPath != "" {
		line := append(append([]byte(nil), next...), '\n')
		defer Wipe(line)
		werr := writeNew(keyPath+".tmp", 0400, func(f *os.File) error {
			_, err := f.Write(line)
			return err
		})
		if werr != nil {
			return werr
		}
		if err := rekeyStep("key-tmp"); err != nil {
			return err
		}
	}
	return renameRekey(dir, agentsTmp, keyPath)
}

func renameRekey(dir, agentsTmp, keyPath string) error {
	if err := syncDirs(dir, keyPath); err != nil {
		return err
	}
	if err := os.Rename(agentsTmp, agentsPath(dir)); err != nil {
		return errors.New("could not seal the agent keys")
	}
	if err := rekeyStep("agents-renamed"); err != nil {
		return err
	}
	if keyPath != "" {
		if err := os.Rename(keyPath+".tmp", keyPath); err != nil {
			return errors.New("could not store the key file")
		}
	}
	return syncDirs(dir, keyPath)
}

// RecoverUnlockKey brings a rekey that stopped part way to one consistent
// state (spec 136 section 4, rotation step 8). With no .tmp file it does
// nothing. A key file that fails StrictModes is refused before anything
// is opened.
func RecoverUnlockKey(dir, keyPath string) error {
	agentsTmp, keyTmp := agentsPath(dir)+".tmp", keyPath+".tmp"
	if !present(agentsTmp) && !present(keyTmp) {
		return nil
	}
	if present(keyPath) {
		cur, err := ReadKeyFile(keyPath)
		if err != nil {
			return err
		}
		ok := opensBundle(dir, cur)
		Wipe(cur)
		if ok {
			os.Remove(agentsTmp)
			os.Remove(keyTmp)
			return syncDirs(dir, keyPath)
		}
	}
	if next, err := ReadKeyFile(keyTmp); err == nil {
		ok := opensBundle(dir, next)
		Wipe(next)
		if ok {
			if err := os.Rename(keyTmp, keyPath); err != nil {
				return errors.New("could not store the key file")
			}
			os.Remove(agentsTmp)
			return syncDirs(dir, keyPath)
		}
	}
	return errors.New("key state is inconsistent: no key file opens the agent keys")
}

func opensBundle(dir string, pass []byte) bool {
	b, err := loadDisk(dir, pass)
	if err != nil {
		return false
	}
	WipeAgents(b.Agents)
	return true
}

func present(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// writeNew creates path (gone first, never followed), fills it and fsyncs.
func writeNew(path string, mode os.FileMode, fill func(*os.File) error) error {
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return errors.New("could not write the key state")
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, mode)
	if err != nil {
		return errors.New("could not write the key state")
	}
	if err := fill(f); err != nil {
		f.Close()
		os.Remove(path)
		return errors.New("could not write the key state")
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(path)
		return errors.New("could not write the key state")
	}
	if err := f.Close(); err != nil {
		os.Remove(path)
		return errors.New("could not write the key state")
	}
	return os.Chmod(path, mode)
}

// syncDirs fsyncs the keys dir and, when it is elsewhere, the key file's dir.
func syncDirs(dir, keyPath string) error {
	dirs := []string{filepath.Join(dir, "keys")}
	if keyPath != "" && filepath.Dir(keyPath) != dirs[0] {
		dirs = append(dirs, filepath.Dir(keyPath))
	}
	for _, d := range dirs {
		f, err := os.Open(d)
		if err != nil {
			return errors.New("could not sync the key state")
		}
		err = f.Sync()
		f.Close()
		if err != nil {
			return errors.New("could not sync the key state")
		}
	}
	return nil
}
