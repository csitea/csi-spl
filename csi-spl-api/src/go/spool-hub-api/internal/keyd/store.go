package keyd

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
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
	rec, err := age.NewScryptRecipient(string(pass))
	if err != nil {
		return errors.New("could not seal the agent keys")
	}
	rec.SetWorkFactor(scryptLogN)
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
	w, err := age.Encrypt(tmp, rec)
	if err != nil {
		tmp.Close()
		return errors.New("could not seal the agent keys")
	}
	if _, err := w.Write(plain); err != nil {
		w.Close()
		tmp.Close()
		return errors.New("could not seal the agent keys")
	}
	if err := w.Close(); err != nil {
		tmp.Close()
		return errors.New("could not seal the agent keys")
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
