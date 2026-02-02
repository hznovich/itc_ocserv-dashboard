package readers

import (
    "bufio"
    "context"
    "os/exec"
)

func SystemdStreamLogs(ctx context.Context, logFile string, streamChan chan<- string) error {
    // WARNING: Use -F (Follow by name) — this allows the process to continue monitoring the log file even after it’s rotated (i.e., when the original file is renamed/moved and a new one is created).
    cmd := exec.Command("tail", "-n", "100", "-F", logFile) 
    stdout, err := cmd.StdoutPipe()
    if err != nil {
	return err
    }
    if err = cmd.Start(); err != nil {
	return err
    }
    
    go func() {
	<-ctx.Done()
	if cmd.Process != nil {
	    cmd.Process.Kill()
	}
    }()

    scanner := bufio.NewScanner(stdout)
    for scanner.Scan() {
	select {
	case <-ctx.Done():
	    return nil
	case streamChan <- scanner.Text():
	}
    }
    return scanner.Err()
}