# Using Check Mate

We can use `check-mate` to _automatically_ watch for hangs or `NaNs` across
multiple files.

- **Watch for `nan`s** in `output.log`:

  ```bash
  ; check-mate-nan --outputs output.log --dry-run &
  ```

- **Watch for hangs**[^bg-process] in any of `--outputs` (`demo.ckpt`, `output.log`):

  ```bash
  ; check-mate-hang --dry-run --grace 6000 --timeout 30 --outputs 'demo.ckpt output.log' &
  ```

  - <details closed><summary><code>--help</code> output:</summary>

    ```bash
    usage: check-mate-hang [-h] [--timeout TIMEOUT] [--check CHECK] [--kill-command KILL_COMMAND] [--outputs OUTPUTS] [--grace GRACE] [--dry-run] [--version]

    Monitor output files for activity and kill a command if it hangs.

    options:
    -h, --help            show this help message and exit
    --timeout TIMEOUT     Seconds of inactivity after which the job will be killed. (default: 300)
    --check CHECK         Seconds between file-activity checks. (default: 5)
    --kill-command KILL_COMMAND
                            Shell command to terminate the job (e.g., 'pkill -u $USER mpiexec'). (default: pkill -u $USER mpiexec)
    --outputs OUTPUTS     Colon-separated list of output files to watch (e.g., 'a.out:train.log'). (default: chkpt/latest)
    --grace GRACE         Seconds to wait after sending the kill command before exiting. (default: 10)
    --dry-run             If set, do not actually run the kill command—only log the action. (default: False)
    --version             show program's version number and exit
    ```

  </details>

  [^bg-process]: Note the trailing `&`, which sends a process to the
  background.

- Launch demo application:

  ```bash
  ; python3 -m check_mate.test --checkpoint demo.ckpt --nan-after 10 --compute 1 --output output.log
  /lus/flare/projects/AuroraGPT/AuroraGPT-v1/Experiments/AuroraGPT-2B/tt/saforem2/checkpoint_restart/venvs/aurora/checkpoint_restart-aurora_frameworks-2025.2.0/lib/python3.10/site-packages/pydantic/_internal/_generate_schema.py:2249: UnsupportedFieldAttributeWarning: The 'repr' attribute with value False was provided to the `Field()` function, which has no effect in the context it was used. 'repr' is field-specific metadata, and can only be attached to a model field using `Annotated` metadata or by assignment. This may have happened because an `Annotated` type alias using the `type` statement was used, or if the `Field()` function was attached to a single member of a union type.
    warnings.warn(
  [2025-10-12 10:37:40,857488][I][check_mate/check_nan:230:main] Monitoring for NaN in: output.log
  [2025-10-12 10:37:40,857346][I][check_mate/check_hang:85:main] Args:
  Namespace(timeout=30, check=5, kill_command='pkill -u $USER mpiexec', outputs='demo.ckpt output.log', grace=6000, dry_run=True)
  [2025-10-12 10:37:40,857939][I][check_mate/test:98:main] Job started at 2025-10-12 10:37:40.857915
  [2025-10-12 10:37:40,859922][I][check_mate/check_hang:91:main] Watching ['demo.ckpt', 'output.log']
  [2025-10-12 10:37:40,860685][I][check_mate/check_hang:107:main] Job monitor started
  [2025-10-12 10:37:40,860680][I][check_mate/test:78:_read_checkpoint] Starting job from scratch
  [2025-10-12 10:37:40,861028][I][check_mate/check_hang:108:main] Watching: demo.ckpt, output.log
  [2025-10-12 10:37:40,861383][I][check_mate/check_hang:109:main] Timeout: 30s | Check interval: 5s
  [2025-10-12 10:37:41,872400][I][check_mate/test:146:main] iter=0 y=0.1305428764894696 dtf=1.001118270040024 dtc=0.0
  [2025-10-12 10:37:42,885140][I][check_mate/test:146:main] iter=1 y=0.6761324528904148 dtf=1.0011026310385205 dtc=0.014563362987246364
  [2025-10-12 10:37:43,893769][I][check_mate/test:146:main] iter=2 y=0.9151647904444832 dtf=1.0011166069889441 dtc=0.008672950963955373
  [2025-10-12 10:37:44,901724][I][check_mate/test:146:main] iter=3 y=0.8635305002902759 dtf=1.0010252799838781 dtc=0.0074560369830578566
  [2025-10-12 10:37:45,867010][I][check_mate/check_hang:148:main] now=2025-10-12 10:37:45 last_change=2025-10-12 10:37:44 runtime_s=5.0 idle_s=1.9
  [2025-10-12 10:37:45,910726][I][check_mate/test:146:main] iter=4 y=0.6555236729537465 dtf=1.0011091149644926 dtc=0.006962783052586019
  [2025-10-12 10:37:46,925133][I][check_mate/test:146:main] iter=5 y=0.37188031152296885 dtf=1.0009411450009793 dtc=0.009035218972712755
  [2025-10-12 10:37:47,935870][I][check_mate/test:146:main] iter=6 y=0.18329204660435794 dtf=1.0003985150251538 dtc=0.013908610038924962
  [2025-10-12 10:37:48,944373][I][check_mate/test:146:main] iter=7 y=0.9036836959960619 dtf=1.0006268019787967 dtc=0.009902971039991826
  [2025-10-12 10:37:49,954481][I][check_mate/test:146:main] iter=8 y=0.6456509288642702 dtf=1.00111193099292 dtc=0.007891696994192898
  [2025-10-12 10:37:50,873025][I][check_mate/check_hang:148:main] now=2025-10-12 10:37:50 last_change=2025-10-12 10:37:49 runtime_s=10.0 idle_s=1.9
  [2025-10-12 10:37:50,965100][I][check_mate/test:146:main] iter=9 y=0.4169184029466545 dtf=1.0011091460473835 dtc=0.00891860103001818
  [2025-10-12 10:37:51,997258][I][check_mate/test:146:main] iter=10 y=nan dtf=1.0002576090046205 dtc=0.01244316401425749
  [2025-10-12 10:37:53,057553][I][check_mate/test:146:main] iter=11 y=nan dtf=1.001112803001888 dtc=0.05139849497936666
  [2025-10-12 10:37:54,081297][I][check_mate/test:146:main] iter=12 y=nan dtf=1.0006589909899049 dtc=0.05290792300365865
  [2025-10-12 10:37:55,090265][I][check_mate/test:146:main] iter=13 y=nan dtf=1.0011217030114494 dtc=0.007073259970638901
  [2025-10-12 10:37:55,875437][I][check_mate/check_hang:148:main] now=2025-10-12 10:37:55 last_change=2025-10-12 10:37:55 runtime_s=15.0 idle_s=0.9
  [2025-10-12 10:37:55,876065][I][check_mate/check_nan:263:main] Detected NaN in output.log.
  [2025-10-12 10:37:55,876723][I][check_mate/check_nan:100:try_kill] [DRY-RUN] Would terminate job (skipping actual kill).
  [2025-10-12 10:37:56,098754][I][check_mate/test:146:main] iter=14 y=nan dtf=1.0007490209536627 dtc=0.007865678984671831
  [2]  + 164277 exit 2     check-mate-nan --outputs output.log --dry-run
  [2025-10-12 10:37:57,112682][I][check_mate/test:146:main] iter=15 y=nan dtf=1.0006822990253568 dtc=0.007701874012127519
  [2025-10-12 10:37:58,121371][I][check_mate/test:146:main] iter=16 y=nan dtf=1.0007786530186422 dtc=0.013263392029330134
  [2025-10-12 10:37:59,128840][I][check_mate/test:146:main] iter=17 y=nan dtf=1.000684988044668 dtc=0.00777538598049432
  [2025-10-12 10:38:00,137200][I][check_mate/test:146:main] iter=18 y=nan dtf=1.0011213249526918 dtc=0.006992085021920502
  [2025-10-12 10:38:00,881627][I][check_mate/check_hang:148:main] now=2025-10-12 10:38:00 last_change=2025-10-12 10:38:00 runtime_s=20.0 idle_s=0.9
  [2025-10-12 10:38:01,147424][I][check_mate/test:146:main] iter=19 y=nan dtf=1.0011180979781784 dtc=0.007436037005390972
  [2025-10-12 10:38:02,160390][I][check_mate/test:146:main] iter=20 y=nan dtf=1.000141775002703 dtc=0.00860474503133446
  [2025-10-12 10:38:03,173537][I][check_mate/test:146:main] iter=21 y=nan dtf=1.0011119630071335 dtc=0.012878089037258178
  [2025-10-12 10:38:04,183006][I][check_mate/test:146:main] iter=22 y=nan dtf=1.0008638399885967 dtc=0.012491002038586885
  [2025-10-12 10:38:05,192267][I][check_mate/test:146:main] iter=23 y=nan dtf=1.0004748729988933 dtc=0.008128960966132581
  [2025-10-12 10:38:05,888000][I][check_mate/check_hang:148:main] now=2025-10-12 10:38:05 last_change=2025-10-12 10:38:05 runtime_s=25.0 idle_s=0.9
  [2025-10-12 10:38:06,209654][I][check_mate/test:146:main] iter=24 y=nan dtf=1.0009121269686148 dtc=0.011071679007727653
  ^Z
  [3]  + 164278 suspended  python3 -m check_mate.test --checkpoint demo.ckpt --nan-after 10 --compute 1
  took: 39s
  ```

  - **Note**: `^Z` suspends the running application, which we use to simulate a
    hang

- Simulated hang:

  ```bash
  #[🐍 aurora_frameworks-2025.2.0](👻 checkpoint_restart-aurora_frameworks-2025.2.0)
  #[/f/A/A/E/A/t/s/checkpoint_restart][🌱 codex/update-project-structure-and-packaging][📦✅] [📦 v0.1.0][⏱️ 39s]
  #[10/12/25 @ 10:38:07][x4117c4s0b0n0]
  ✦2 ; [2025-10-12 10:38:10,894041][I][check_mate/check_hang:148:main] now=2025-10-12 10:38:10 last_change=2025-10-12 10:38:06 runtime_s=30.0 idle_s=4.9
  [2025-10-12 10:38:15,900805][I][check_mate/check_hang:148:main] now=2025-10-12 10:38:15 last_change=2025-10-12 10:38:06 runtime_s=35.0 idle_s=9.9
  [2025-10-12 10:38:20,907240][I][check_mate/check_hang:148:main] now=2025-10-12 10:38:20 last_change=2025-10-12 10:38:06 runtime_s=40.0 idle_s=14.9
  [2025-10-12 10:38:25,910933][I][check_mate/check_hang:148:main] now=2025-10-12 10:38:25 last_change=2025-10-12 10:38:06 runtime_s=45.1 idle_s=19.9
  [2025-10-12 10:38:30,917603][I][check_mate/check_hang:148:main] now=2025-10-12 10:38:30 last_change=2025-10-12 10:38:06 runtime_s=50.1 idle_s=24.9
  [2025-10-12 10:38:35,922839][I][check_mate/check_hang:148:main] now=2025-10-12 10:38:35 last_change=2025-10-12 10:38:06 runtime_s=55.1 idle_s=29.9
  [2025-10-12 10:38:40,929635][I][check_mate/check_hang:148:main] now=2025-10-12 10:38:40 last_change=2025-10-12 10:38:06 runtime_s=60.1 idle_s=34.9
  [2025-10-12 10:38:40,930635][I][check_mate/check_hang:152:main] [2025-10-12 10:38:40] Output has not been updated for 34.9 seconds. Issuing kill command...
  [2025-10-12 10:38:40,931162][I][check_mate/check_hang:172:main] (dry-run) Skipping kill execution
  [2025-10-12 10:38:40,931535][I][check_mate/check_hang:174:main] Monitor exiting after inactivity timeout.

  [1]  - 164276 done       check-mate-hang --dry-run --grace 6000 --timeout 30 --outputs
  ```
