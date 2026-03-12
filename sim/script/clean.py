import re
from datetime import datetime  

INPUT_FILENAME = 'original_log.txt'

def clean_isim_log():
    try:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_filename = f'cleaned_log_{timestamp}.txt'

        with open(INPUT_FILENAME, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        with open(output_filename, 'w', encoding='utf-8') as f_out:
            skip_next_lines = 0
            for line in lines:
                if "WARNING:Simulator:" in line:
                    skip_next_lines = 2
                    continue
                
                if skip_next_lines > 0 and (line.startswith('  ') or 'ns)' in line):
                    skip_next_lines -= 1
                    continue
                
                f_out.write(line)
        
        print(f"DONE! FILE SAVED TO: {output_filename}")
        
    except FileNotFoundError:
        print(f"ERROR!!! NO SUCH FILE '{INPUT_FILENAME}', CHECK THE NAME")

if __name__ == "__main__":
    clean_isim_log()