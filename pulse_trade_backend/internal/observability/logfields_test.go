package observability_test

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// logCallMethods are the `Logger` methods whose first argument is a message slug
// and whose remaining arguments alternate field name / value.
var logCallMethods = map[string]bool{
	"Info":  true,
	"Warn":  true,
	"Error": true,
	"Debug": true,
}

// TestLogFieldsComeFromConstants enforces the rule that field names and
// message slugs are identifiers from the schema's constants file rather than
// string literals typed at the call site.
//
// A literal is exactly the failure mode the rule exists to prevent: `"duratonMs"`
// next to `"durationMs"` is valid Go, passes the compiler, and silently splits one
// metric across two `jq` keys. Renaming a constant instead updates every call site
// and every dashboard with it.
//
// This is an AST walk rather than a `grep` because the distinction that matters is
// *syntactic position*: the same string literal is fine as a value (a reason code,
// a route) and wrong as a key. Parsing also means a literal hidden by a line break
// or a wrapped argument list cannot slip past.
func TestLogFieldsComeFromConstants(t *testing.T) {
	root := moduleRoot(t)

	var violations []string
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			name := entry.Name()
			// The workspace keeps its Go module cache inside the repo.
			if strings.HasPrefix(name, ".") || name == "vendor" || name == "testdata" {
				return fs.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") {
			return nil
		}
		found, err := literalLogArguments(path)
		if err != nil {
			return err
		}
		relative, relErr := filepath.Rel(root, path)
		if relErr != nil {
			relative = path
		}
		for _, finding := range found {
			violations = append(violations, fmt.Sprintf("%s:%d %s", relative, finding.line, finding.detail))
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk module: %v", err)
	}

	sort.Strings(violations)
	if len(violations) > 0 {
		t.Errorf("%d logger argument(s) are string literals; use the constants in "+
			"internal/observability/logfields.go:\n\t%s",
			len(violations), strings.Join(violations, "\n\t"))
	}
}

// finding is one literal used where a schema identifier belongs.
type finding struct {
	line   int
	detail string
}

// literalLogArguments parses one file and reports string literals in the message
// or field-name position of any logger call.
func literalLogArguments(path string) ([]finding, error) {
	source, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, source, 0)
	if err != nil {
		return nil, err
	}

	var out []finding
	ast.Inspect(file, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok {
			return true
		}
		selector, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		position := fset.Position(call.Pos())

		switch {
		case logCallMethods[selector.Sel.Name]:
			// `logger.Info(slug, key, value...)`: argument 0 and every even
			// argument after it are schema identifiers.
			if len(call.Args) == 0 {
				return true
			}
			if detail, bad := literalDetail(call.Args[0]); bad {
				out = append(out, finding{position.Line, "message slug " + detail})
			}
			for index := 1; index < len(call.Args); index += 2 {
				if detail, bad := literalDetail(call.Args[index]); bad {
					out = append(out, finding{position.Line, "field name " + detail})
				}
			}
		case isSlogIdent(selector.X):
			// `slog.String("key", v)`: the key is always argument 0.
			if len(call.Args) > 0 {
				if detail, bad := literalDetail(call.Args[0]); bad {
					out = append(out, finding{position.Line, selector.Sel.Name + " key " + detail})
				}
			}
		}
		return true
	})
	return out, nil
}

// literalDetail reports whether arg is a string literal, and formats it.
func literalDetail(arg ast.Expr) (string, bool) {
	literal, ok := arg.(*ast.BasicLit)
	if !ok || literal.Kind != token.STRING {
		return "", false
	}
	value, err := strconv.Unquote(literal.Value)
	if err != nil {
		value = literal.Value
	}
	return fmt.Sprintf("%q", value), true
}

// isSlogIdent reports whether expression is the `slog` package selector.
func isSlogIdent(expression ast.Expr) bool {
	ident, ok := expression.(*ast.Ident)
	return ok && ident.Name == "slog"
}

// moduleRoot walks up from this file until it finds the `go.mod` that owns it.
func moduleRoot(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the test file")
	}
	dir := filepath.Dir(thisFile)
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("no go.mod above the test file")
		}
		dir = parent
	}
}
