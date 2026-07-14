[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $File,
    [Parameter(Mandatory = $true)]
    [string] $CandidateClass,
    [string] $Member = "",
    [string] $SqlLiteral = "",
    [string] $ConstantName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-JdkTool {
    param([string] $ToolName)

    if ($env:JAVA_HOME) {
        $candidate = Join-Path $env:JAVA_HOME "bin/$ToolName"
        if (Test-Path $candidate) { return $candidate }
        $candidateExe = "$candidate.exe"
        if (Test-Path $candidateExe) { return $candidateExe }
    }

    $command = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "Unable to locate JDK tool '$ToolName'. Set JAVA_HOME to a JDK."
}

if (-not (Test-Path $File)) {
    throw "Java candidate file not found: $File"
}

function Test-SimpleStringConstantLine {
    param([string] $Line)
    return $Line -match '^\s*private static final String [A-Z0-9_]+ = "[^"\\]+";\s*$'
}

if ($CandidateClass -notin @("repository_readability_cleanup", "redundant_local_variable_simplification")) {
    Write-Host "astVerificationSkipped=true"
    Write-Host "candidateClass=$CandidateClass"
    exit 0
}

if ($CandidateClass -eq "repository_readability_cleanup" -and $Member.StartsWith("line-")) {
    $lineNumber = [int]($Member.Substring(5))
    $lines = Get-Content $File
    if ($lineNumber -lt 1 -or $lineNumber -gt $lines.Count) {
        throw "AST-lite line verification failed: line $lineNumber outside $File"
    }
    if (-not (Test-SimpleStringConstantLine $lines[$lineNumber - 1])) {
        throw "AST-lite line verification failed: unsupported line cleanup in $File"
    }
    Write-Host "astVerificationPassed=true"
    Write-Host "verificationMode=line-constant"
    exit 0
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("threshold-java-ast-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null
$javaSourcePath = Join-Path $tempDir "VerifyJavaCandidateAst.java"

$javaSource = @'
import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import javax.tools.DiagnosticCollector;
import javax.tools.JavaCompiler;
import javax.tools.JavaFileObject;
import javax.tools.StandardJavaFileManager;
import javax.tools.ToolProvider;
import com.sun.source.tree.BinaryTree;
import com.sun.source.tree.BlockTree;
import com.sun.source.tree.CompilationUnitTree;
import com.sun.source.tree.ExpressionTree;
import com.sun.source.tree.IdentifierTree;
import com.sun.source.tree.LiteralTree;
import com.sun.source.tree.MethodInvocationTree;
import com.sun.source.tree.MethodTree;
import com.sun.source.tree.ReturnTree;
import com.sun.source.tree.StatementTree;
import com.sun.source.tree.Tree;
import com.sun.source.tree.VariableTree;
import com.sun.source.util.JavacTask;
import com.sun.source.util.TreeScanner;

public class VerifyJavaCandidateAst {

    private static final class MethodCollector extends TreeScanner<Void, Void> {
        final List<MethodTree> methods = new ArrayList<>();
        final List<VariableTree> variables = new ArrayList<>();

        @Override
        public Void visitMethod(MethodTree node, Void unused) {
            methods.add(node);
            return super.visitMethod(node, unused);
        }

        @Override
        public Void visitVariable(VariableTree node, Void unused) {
            variables.add(node);
            return super.visitVariable(node, unused);
        }
    }

    private static final class QueryInvocationCounter extends TreeScanner<Void, Void> {
        int count = 0;

        @Override
        public Void visitMethodInvocation(MethodInvocationTree node, Void unused) {
            String select = node.getMethodSelect().toString();
            if ((select.endsWith(".sql") || select.endsWith(".createQuery")) && !node.getArguments().isEmpty()) {
                ExpressionTree firstArg = node.getArguments().get(0);
                if (isStringExpression(firstArg)) {
                    count++;
                }
            }
            return super.visitMethodInvocation(node, unused);
        }
    }

    private static boolean isStringExpression(ExpressionTree tree) {
        if (tree instanceof LiteralTree) {
            Object value = ((LiteralTree) tree).getValue();
            return value instanceof String;
        }
        if (tree instanceof BinaryTree) {
            BinaryTree binary = (BinaryTree) tree;
            return isStringExpression(binary.getLeftOperand()) && isStringExpression(binary.getRightOperand());
        }
        return false;
    }

    private static boolean hasVariable(String name, MethodCollector collector) {
        for (VariableTree variable : collector.variables) {
            if (variable.getName().contentEquals(name)) {
                return true;
            }
        }
        return false;
    }

    private static MethodTree findMethod(String name, MethodCollector collector) {
        MethodTree found = null;
        for (MethodTree method : collector.methods) {
            if (method.getName().contentEquals(name)) {
                if (found != null) {
                    throw new IllegalStateException("method is not unique: " + name);
                }
                found = method;
            }
        }
        return found;
    }

    private static int countImmediateReturnLocal(String variableName, MethodCollector collector) {
        int matches = 0;
        for (MethodTree method : collector.methods) {
            BlockTree body = method.getBody();
            if (body == null) {
                continue;
            }
            List<? extends StatementTree> statements = body.getStatements();
            for (int i = 0; i < statements.size() - 1; i++) {
                StatementTree current = statements.get(i);
                StatementTree next = statements.get(i + 1);
                if (!(current instanceof VariableTree) || !(next instanceof ReturnTree)) {
                    continue;
                }
                VariableTree variable = (VariableTree) current;
                if (!variable.getName().contentEquals(variableName) || variable.getInitializer() == null) {
                    continue;
                }
                ExpressionTree returnExpression = ((ReturnTree) next).getExpression();
                if (returnExpression instanceof IdentifierTree &&
                        ((IdentifierTree) returnExpression).getName().contentEquals(variableName)) {
                    matches++;
                }
            }
        }
        return matches;
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            throw new IllegalArgumentException("usage: <file> <candidateClass> <member> [constantName]");
        }
        Path file = Path.of(args[0]);
        String candidateClass = args[1];
        String member = args[2];
        String constantName = args.length > 3 ? args[3] : "";

        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        if (compiler == null) {
            throw new IllegalStateException("JDK compiler is not available.");
        }

        DiagnosticCollector<JavaFileObject> diagnostics = new DiagnosticCollector<>();
        try (StandardJavaFileManager fileManager =
                compiler.getStandardFileManager(diagnostics, null, null)) {
            Iterable<? extends JavaFileObject> files = fileManager.getJavaFileObjects(file.toFile());
            JavacTask task = (JavacTask) compiler.getTask(
                null,
                fileManager,
                diagnostics,
                Arrays.asList("-proc:none"),
                null,
                files
            );
            Iterable<? extends CompilationUnitTree> units = task.parse();
            MethodCollector collector = new MethodCollector();
            for (CompilationUnitTree unit : units) {
                collector.scan(unit, null);
            }

            if ("repository_readability_cleanup".equals(candidateClass)) {
                if (constantName == null || constantName.isBlank()) {
                    throw new IllegalStateException("repository candidate is missing constantName");
                }
                if (hasVariable(constantName, collector)) {
                    throw new IllegalStateException("constant already exists: " + constantName);
                }
                MethodTree method = findMethod(member, collector);
                if (method == null) {
                    throw new IllegalStateException("method not found: " + member);
                }
                QueryInvocationCounter counter = new QueryInvocationCounter();
                counter.scan(method, null);
                if (counter.count != 1) {
                    throw new IllegalStateException("expected exactly one string query invocation in method " +
                        member + ", found " + counter.count);
                }
            } else if ("redundant_local_variable_simplification".equals(candidateClass)) {
                int matches = countImmediateReturnLocal(member, collector);
                if (matches != 1) {
                    throw new IllegalStateException("expected exactly one immediate return-local pattern for " +
                        member + ", found " + matches);
                }
            } else {
                throw new IllegalArgumentException("unsupported AST-lite candidate class: " + candidateClass);
            }
        } catch (IOException ex) {
            throw new IllegalStateException("could not read candidate file: " + file, ex);
        }

        System.out.println("astVerificationPassed=true");
        System.out.println("verificationMode=jdk-compiler-tree-api");
    }
}
'@

try {
    $encoding = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($javaSourcePath, $javaSource, $encoding)

    $javac = Resolve-JdkTool "javac"
    $java = Resolve-JdkTool "java"

    & $javac --add-modules jdk.compiler -d $tempDir $javaSourcePath
    if ($LASTEXITCODE -ne 0) {
        throw "AST-lite verifier compilation failed."
    }

    $resolvedFile = (Resolve-Path -LiteralPath $File).Path
    & $java --add-modules jdk.compiler -cp $tempDir VerifyJavaCandidateAst `
        $resolvedFile `
        $CandidateClass `
        $Member `
        $ConstantName
    if ($LASTEXITCODE -ne 0) {
        throw "AST-lite verifier rejected candidate."
    }
} finally {
    if (Test-Path $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}
