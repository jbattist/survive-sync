#!/usr/bin/env python3
import os
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "sync" / "sync-classics.sh"


def run_sync(src: Path, dest: Path, metadata: Path, extra_env=None):
    log = metadata / "sync.log"
    env = os.environ.copy()
    env.update(
        {
            "CLASSICS_NFS_MOUNT": str(src),
            "CLASSICS_DEST_DIR": str(dest),
            "CLASSICS_METADATA_DIR": str(metadata),
            "CLASSICS_SKIP_MOUNT_CHECK": "1",
            "CLASSICS_BWLIMIT": "0",
        }
    )
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(SCRIPT), "--log", str(log)],
        cwd=REPO,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def test_cached_manifest_syncs_only_selected_movies_and_deletes_deselected_content():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        src = root / "src"
        dest = root / "dest"
        metadata = root / "metadata"
        src.mkdir()
        dest.mkdir()
        metadata.mkdir()

        (src / "Casablanca (1942)").mkdir()
        (src / "Casablanca (1942)" / "movie.mkv").write_text("keep", encoding="utf-8")
        (src / "Not Selected (1950)").mkdir()
        (src / "Not Selected (1950)" / "movie.mkv").write_text("skip", encoding="utf-8")

        (dest / "Old Deselected (1930)").mkdir()
        (dest / "Old Deselected (1930)" / "movie.mkv").write_text("delete me", encoding="utf-8")
        (dest / "Casablanca (1942)").mkdir()
        (dest / "Casablanca (1942)" / "old-extra.srt").write_text("stale", encoding="utf-8")

        (metadata / "classics-survive-manifest.txt").write_text("Casablanca (1942)/\n", encoding="utf-8")

        result = run_sync(src, dest, metadata)

        assert result.returncode == 0, result.stdout
        assert (dest / "Casablanca (1942)" / "movie.mkv").read_text(encoding="utf-8") == "keep"
        assert not (dest / "Not Selected (1950)").exists()
        assert not (dest / "Old Deselected (1930)").exists()
        assert not (dest / "Casablanca (1942)" / "old-extra.srt").exists()
        assert "DEL Old Deselected (1930)/movie.mkv" in result.stdout
        assert "Using cached Radarr manifest" in result.stdout


def test_radarr_refresh_writes_cached_manifest_from_survive_tag_before_sync():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        src = root / "src"
        dest = root / "dest"
        metadata = root / "metadata"
        fakebin = root / "bin"
        src.mkdir()
        dest.mkdir()
        metadata.mkdir()
        fakebin.mkdir()

        (src / "Seven Samurai (1954)").mkdir()
        (src / "Seven Samurai (1954)" / "movie.mkv").write_text("selected", encoding="utf-8")
        (src / "Unselected (1960)").mkdir()
        (src / "Unselected (1960)" / "movie.mkv").write_text("no", encoding="utf-8")

        curl = fakebin / "curl"
        curl.write_text(
            "#!/usr/bin/env bash\n"
            "case \"$*\" in\n"
            "  *'/api/v3/tag'*) printf '%s' '[{\"id\":7,\"label\":\"survive\"}]' ;;\n"
            "  *'/api/v3/movie'*) printf '%s' '[{\"title\":\"Seven Samurai\",\"year\":1954,\"path\":\"/media-classics/Seven Samurai (1954)\",\"tags\":[7]},{\"title\":\"Unselected\",\"year\":1960,\"path\":\"/media-classics/Unselected (1960)\",\"tags\":[]}]' ;;\n"
            "  *) exit 22 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        curl.chmod(0o755)

        result = run_sync(
            src,
            dest,
            metadata,
            {
                "PATH": f"{fakebin}:{os.environ['PATH']}",
                "RADARR_URL": "http://radarr.test",
                "RADARR_API_KEY": "secret",
                "RADARR_SYNC_TAG": "survive",
            },
        )

        assert result.returncode == 0, result.stdout
        assert (metadata / "classics-survive-manifest.txt").read_text(encoding="utf-8") == "Seven Samurai (1954)/\n"
        assert (dest / "Seven Samurai (1954)" / "movie.mkv").exists()
        assert not (dest / "Unselected (1960)").exists()
        assert "Refreshed Radarr manifest: 1 movie(s) tagged survive" in result.stdout


def test_dry_run_reports_deletes_without_modifying_destination():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        src = root / "src"
        dest = root / "dest"
        metadata = root / "metadata"
        src.mkdir()
        dest.mkdir()
        metadata.mkdir()

        (src / "Casablanca (1942)").mkdir()
        (src / "Casablanca (1942)" / "movie.mkv").write_text("keep", encoding="utf-8")
        (dest / "Old Deselected (1930)").mkdir()
        (dest / "Old Deselected (1930)" / "movie.mkv").write_text("delete me", encoding="utf-8")
        (metadata / "classics-survive-manifest.txt").write_text("Casablanca (1942)/\n", encoding="utf-8")

        result = run_sync(src, dest, metadata, {"CLASSICS_DRY_RUN": "1"})

        assert result.returncode == 0, result.stdout
        assert (dest / "Old Deselected (1930)" / "movie.mkv").exists()
        assert not (dest / "Casablanca (1942)" / "movie.mkv").exists()
        assert "DRY RUN enabled" in result.stdout
        assert "DEL Old Deselected (1930)/movie.mkv" in result.stdout


def test_rsync_uses_size_only_to_avoid_timestamp_only_recopies():
    script = SCRIPT.read_text(encoding="utf-8")
    assert "--size-only" in script


def test_rsync_filter_does_not_keep_all_directories():
    script = SCRIPT.read_text(encoding="utf-8")
    assert 'print("+ */")' not in script
    assert "keeps\n        # deselected movie directories around" in script


if __name__ == "__main__":
    test_cached_manifest_syncs_only_selected_movies_and_deletes_deselected_content()
    test_radarr_refresh_writes_cached_manifest_from_survive_tag_before_sync()
    test_dry_run_reports_deletes_without_modifying_destination()
    test_rsync_uses_size_only_to_avoid_timestamp_only_recopies()
    test_rsync_filter_does_not_keep_all_directories()
    print("ok")
