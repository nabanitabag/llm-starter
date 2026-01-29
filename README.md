1. Clone this repo on your local machine. Then, login to CHTC and clone this repo there as well: 
```aiignore
git clone git@github.com:Badger-RL/llm-starter.git
./login_chtc.sh
git clone git@github.com:Badger-RL/llm-starter.git
```
We do all code development on your local machine. 
We submit jobs from CHTC. 
When submitting jobs, we'll only use scripts the `chtc` directory.

1. On your local machine, add your wandb and huggingface login info to `chtc/job.sh`
```aiignore
wandb login <your wandb key>
huggingface-cli login --token <your hf token>
```
The code will run even if you comment out these lines (they're currently commented out), 
but you'll need to set it up eventually, since we'll be using wandb and huggingface for logging and model storage.

2.  On your local machine, transfer your code to your CHTC staging directory:
```aiignore
cd chtc
./transfer_to_chtc.sh
```
If you make changes to your code, you will need to transfer again to ensure CHTC jobs run on the latest version.

3. On your CHTC submit node, submit an interactive job:
```aiignore
cd llm-starter/chtc
./submit_interactive.sh 1
```
The argument after `submit_interactive.sh` is the number of GPUs you want to use. 
You can use at most 4 in an interactive job.

4. Wait for CHTC to match you to a machine (this can take a few minutes). Once the job starts, run the demo:
```aiignore
chmod +x job.sh
./job.sh
```
You can also just copy-paste the commands from `job.sh` into your terminal, which is what I usually do when I need to add/remove commands for testing/debugging/etc.